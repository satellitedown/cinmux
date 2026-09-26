#pragma once

class QCoreApplication;

// Runs `cinmux tui`: the Cinmux workspace inside the current terminal (for
// example over SSH), sharing sessions, folders and notifications with the GUI.
int runTui(QCoreApplication &app);
