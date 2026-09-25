import { execFile } from "node:child_process";
import { isAbsolute } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

type Activity = "idle" | "working" | "waiting" | "done";
type Report = {
	owner: symbol;
	state: Activity;
	detail: string;
	executable: string;
	session: string;
	stateDir: string;
	warn: (message: string) => void;
};
type Channel = {
	owner?: symbol;
	release?: () => void;
	pending?: Report;
	writing: boolean;
	written?: string;
	warning?: string;
};

// Factories are rebound in headless children and modules can be reimported on
// /reload. Keep the writer process-wide, but claim it ONLY from session_start
// with an interactive context. A retired instance cannot reclaim ownership.
const registryKey = Symbol.for("io.niay.cinmux.omp-activity.writers");
const host = globalThis as typeof globalThis & { [registryKey]?: Map<string, Channel> };

function plain(value: unknown, limit = 160): string {
	return typeof value === "string"
		? value.slice(0, 1024).replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, " ")
			.replace(/\s+/g, " ").trim().slice(0, limit)
		: "";
}

function writeReport(report: Report): Promise<string | undefined> {
	const { promise, resolve } = Promise.withResolvers<string | undefined>();
	try {
		execFile(report.executable, [
			"activity", "--state", report.state, "--pid", String(process.pid),
			"--session", report.session, "--detail", report.detail,
		], {
			env: { ...process.env, CINMUX_STATE_DIR: report.stateDir },
			timeout: 3000,
			killSignal: "SIGKILL",
			maxBuffer: 4096,
			encoding: "utf8",
		}, (error, _stdout, stderr) => {
			resolve(error ? plain(stderr) || plain(error.message) || "activity command failed" : undefined);
		});
	} catch (error) {
		resolve(plain(error instanceof Error ? error.message : String(error)) || "activity command failed");
	}
	return promise;
}

async function drain(channel: Channel): Promise<void> {
	channel.writing = true;
	try {
		while (channel.pending) {
			const report = channel.pending;
			channel.pending = undefined;
			const key = `${report.state}\n${report.detail}`;
			if (channel.owner !== report.owner || channel.written === key) continue;
			const failure = await writeReport(report);
			if (failure) {
				channel.written = undefined;
				if (channel.owner === report.owner && channel.warning !== failure) {
					channel.warning = failure;
					report.warn(failure);
				}
			} else {
				channel.written = key;
				channel.warning = undefined;
			}
		}
	} finally {
		channel.writing = false;
	}
}

/** OMP 18.2.11: lifecycle observations only; never installs approval middleware. */
export default function cinmuxActivity(pi: ExtensionAPI): void {
	const session = process.env.CINMUX_SESSION_ID;
	const stateDir = process.env.CINMUX_STATE_DIR;
	if (!session || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(session)
		|| !stateDir || !isAbsolute(stateDir) || stateDir.includes("\0")) return;

	const executable = process.env.CINMUX_EXECUTABLE || "cinmux";
	const owner = Symbol("cinmux-activity-instance");
	let channel: Channel | undefined;
	let context: ExtensionContext | undefined;
	let retired = false;
	let timer: Timer | undefined;
	let requested: string | undefined;
	const asks = new Map<string, string>();
	const approvals = new Map<string, string>();
	const tools = new Map<string, string>();
	const backgroundJobs = new Set<string>();
	let backgroundFailed = false;
	let working = false;
	let lastStopReason: string | undefined;
	let successfulYield = false;
	let yieldCall: string | undefined;
	let ended: { success: boolean; willContinue: boolean; hadBackground: boolean } | undefined;

	function owns(ctx: ExtensionContext): boolean {
		return !retired && ctx.hasUI && channel?.owner === owner;
	}

	// This is also called from the detached writer. Logging/UI failures must not
	// become an unhandled rejection or tear down a normal OMP tool execution.
	function warn(message: string): void {
		const text = `Cinmux activity: ${plain(message)}`;
		try { pi.logger.warn(text); } catch { /* The UI remains a second reporting path. */ }
		try { context?.ui.notify(text, "warning"); } catch { /* Logging was attempted above. */ }
	}

	function publish(state: Activity, detail = ""): void {
		if (!channel || channel.owner !== owner || retired) return;
		const text = plain(detail);
		const key = `${state}\n${text}`;
		if (requested === key) return;
		requested = key;
		const report: Report = { owner, state, detail: text, executable, session: session!, stateDir: stateDir!, warn };
		// At most one subprocess and one latest-state slot, including across reload.
		// A former owner's in-flight write finishes BEFORE the new owner's write.
		channel.pending = report;
		if (!channel.writing) void drain(channel).catch(error => warn(String(error)));
	}

	function clearTimer(): void {
		if (timer !== undefined) context?.clearTimer(timer);
		timer = undefined;
	}

	function release(): void {
		retired = true;
		clearTimer();
	}

	function reset(ctx: ExtensionContext): void {
		if (!owns(ctx)) return;
		context = ctx;
		clearTimer();
		asks.clear();
		approvals.clear();
		tools.clear();
		backgroundJobs.clear();
		backgroundFailed = false;
		lastStopReason = undefined;
		successfulYield = false;
		yieldCall = undefined;
		ended = undefined;
		working = false;
		publish("idle");
	}

	function observeJobs(ctx: ExtensionContext): boolean {
		const snapshot = ctx.getAsyncJobSnapshot();
		if (!snapshot) return false; // No async-job manager is owned by this context.
		for (const job of snapshot.running) backgroundJobs.add(job.id);
		for (const job of snapshot.recent) {
			if (backgroundJobs.has(job.id) && (job.status === "cancelled" || job.status === "failed")) {
				backgroundFailed = true;
			}
			if (job.status !== "running") backgroundJobs.delete(job.id);
		}
		return snapshot.running.length > 0 || snapshot.delivery.queued > 0
			|| snapshot.delivery.delivering || snapshot.delivery.pendingJobIds.length > 0;
	}

	function showWorking(): void {
		const permission = approvals.values().next().value;
		const question = asks.values().next().value;
		if (permission || question) publish("waiting", permission || question);
		else publish("working", tools.values().next().value || "OMP working");
	}

	function scheduleSettle(ctx: ExtensionContext): void {
		if (timer !== undefined) return;
		// Only active while an agent_end is awaiting actual quiescence. Managed
		// timers are isolated, unref'd and automatically cleared on shutdown.
		timer = ctx.setTimeout(() => {
			timer = undefined;
			if (owns(ctx)) settle(ctx);
		}, 250);
	}

	function settle(ctx: ExtensionContext): void {
		if (!owns(ctx) || !ended) return;
		const background = observeJobs(ctx);
		if (asks.size || approvals.size || !ctx.isIdle() || ctx.hasPendingMessages() || background) {
			showWorking();
			scheduleSettle(ctx);
			return;
		}
		// willContinue is authoritative: retry/maintenance/stop-hook continuations
		// can be scheduled even when both the job snapshot and message queue are
		// briefly empty. Never turn that gap into Done. Cancelled background work
		// can settle without another agent_end (Escape while awaiting a child).
		if (ended.willContinue && !(ended.hadBackground && backgroundFailed)) {
			showWorking();
			scheduleSettle(ctx);
			return;
		}
		const success = ended.success && !ended.willContinue && !backgroundFailed;
		ended = undefined;
		working = false;
		tools.clear();
		backgroundJobs.clear();
		backgroundFailed = false;
		clearTimer();
		publish(success ? "done" : "idle", success ? "OMP done" : "");
	}

	function startWork(ctx: ExtensionContext): void {
		if (!owns(ctx)) return;
		context = ctx;
		clearTimer();
		ended = undefined;
		lastStopReason = undefined;
		backgroundFailed = false;
		successfulYield = false;
		yieldCall = undefined;
		working = true;
		showWorking();
	}

	pi.on("session_start", (_event, ctx) => {
		// RPC/ACP can provide hasUI too. Restrict discovery to the real terminal
		// interactive host; rebound task/eval children have hasUI === false.
		if (retired || !ctx.hasUI || !process.stdin.isTTY || !process.stdout.isTTY) return;
		const registry = host[registryKey] ??= new Map();
		const key = `${stateDir}\0${session}`;
		channel = registry.get(key);
		if (!channel) {
			channel = { writing: false };
			registry.set(key, channel);
		}
		if (channel.owner !== owner) channel.release?.();
		channel.owner = owner;
		channel.release = release;
		channel.pending = undefined;
		context = ctx;
		reset(ctx);
	});
	pi.on("session_switch", (_event, ctx) => reset(ctx));
	pi.on("session_branch", (_event, ctx) => reset(ctx));
	pi.on("session_tree", (_event, ctx) => reset(ctx));
	pi.on("agent_start", (_event, ctx) => startWork(ctx));
	pi.on("auto_retry_start", (_event, ctx) => startWork(ctx));

	pi.on("tool_execution_start", (event, ctx) => {
		if (!owns(ctx)) return;
		tools.set(event.toolCallId, plain(event.toolName) || "OMP working");
		if (event.toolName === "ask") {
			const args = event.args as { questions?: { question?: unknown }[] } | undefined;
			const question = Array.isArray(args?.questions) ? plain(args.questions[0]?.question) : "";
			asks.set(event.toolCallId, question || "Needs input");
		}
		if (event.toolName === "yield") {
			const args = event.args as { type?: unknown; error?: unknown } | undefined;
			if (!Array.isArray(args?.type) && !args?.error) yieldCall = event.toolCallId;
		}
		showWorking();
	});
	pi.on("tool_execution_end", (event, ctx) => {
		if (!owns(ctx)) return;
		tools.delete(event.toolCallId);
		asks.delete(event.toolCallId);
		approvals.delete(event.toolCallId);
		if (event.toolCallId === yieldCall) successfulYield = !event.isError;
		observeJobs(ctx);
		if (working) showWorking();
	});
	pi.on("tool_approval_requested", (event, ctx) => {
		if (!owns(ctx)) return;
		approvals.set(event.toolCallId, `Permission requested: ${plain(event.toolName)}`);
		showWorking();
	});
	pi.on("tool_approval_resolved", (event, ctx) => {
		if (!owns(ctx)) return;
		// Observational only: never return a decision or call a UI approval API.
		approvals.delete(event.toolCallId);
		showWorking();
	});
	pi.on("message_end", (event, ctx) => {
		if (owns(ctx) && working && event.message.role === "assistant") lastStopReason = event.message.stopReason;
	});
	pi.on("agent_end", (event, ctx) => {
		if (!owns(ctx) || !working) return;
		const last = event.messages.findLast(message => message.role === "assistant");
		const reason = lastStopReason ?? (last?.role === "assistant" ? last.stopReason : undefined);
		ended = {
			success: reason === "stop" || (reason === "toolUse" && successfulYield),
			willContinue: event.willContinue === true,
			hadBackground: observeJobs(ctx),
		};
		// agent_end handlers run before every host settle/unwind has completed.
		// Defer the first snapshot too, then require idle + empty queues/jobs.
		scheduleSettle(ctx);
	});
	pi.on("auto_retry_end", (event, ctx) => {
		if (!owns(ctx) || event.success) return;
		ended = { success: false, willContinue: false, hadBackground: false };
		scheduleSettle(ctx);
	});
	pi.on("session_shutdown", (_event, ctx) => {
		if (!owns(ctx)) return;
		publish("idle");
		release();
		// Do not hold shutdown on SQLite/subprocess I/O. The bounded writer may
		// finish; Cinmux also removes this report when process.pid is no longer live.
	});
}
