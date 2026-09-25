#include "terminal_surface_item.h"
#include "terminal_compositor.h"
#include <QGuiApplication>
#include <QInputMethod>
#include <QInputMethodEvent>
#include <QMouseEvent>
#include <QQuickWindow>
#include <QSGOpacityNode>
#include <QSGSimpleTextureNode>
#include <QSGTexture>

namespace {
class TextureNode : public QSGSimpleTextureNode {
public:
    ~TextureNode() override { delete texture(); }
    void replace(QSGTexture *next) {
        auto *previous = texture(); setTexture(next); delete previous;
        setFiltering(QSGTexture::Linear);
    }
};
class SurfaceNode : public QSGNode {
public:
    TextureNode *terminal = nullptr;
    QSGOpacityNode *cursorOpacity = nullptr;
    TextureNode *cursor = nullptr;
    quint64 frameRevision = 0;
    quint64 cursorRevision = 0;
    const TerminalView *view = nullptr;
};
}

TerminalSurfaceItem::TerminalSurfaceItem(QQuickItem *parent) : QQuickItem(parent) {
    setFlag(ItemHasContents, true);
    setFlag(ItemAcceptsInputMethod, true);
    setAcceptedMouseButtons(Qt::AllButtons);
    setAcceptHoverEvents(true);
    setClip(true);
    connect(this, &QQuickItem::activeFocusChanged, this, [this] {
        if (m_compositor && hasActiveFocus() && m_view) m_compositor->focusTerminal(m_view->sessionId());
        QGuiApplication::inputMethod()->update(Qt::ImQueryAll);
    });
}
QObject *TerminalSurfaceItem::view() const { return m_view; }
QObject *TerminalSurfaceItem::compositor() const { return m_compositor; }
void TerminalSurfaceItem::setView(QObject *object) {
    auto *view = qobject_cast<TerminalView *>(object);
    if (m_view == view) return;
    if (m_view) disconnect(m_view, nullptr, this, nullptr);
    m_view = view;
    if (m_view) {
        connect(m_view, &TerminalView::frameChanged, this, &QQuickItem::update);
        connect(m_view, &TerminalView::cursorChanged, this, [this] { updateCursor(); update(); });
        connect(m_view, &QObject::destroyed, this, [this] { m_view = nullptr; updateCursor(); update(); });
    }
    if (m_compositor) m_compositor->registerItem(m_view, this);
    configure(); update(); emit viewChanged();
}
void TerminalSurfaceItem::setCompositor(QObject *object) {
    auto *compositor = qobject_cast<TerminalCompositor *>(object);
    if (m_compositor == compositor) return;
    if (m_compositor) disconnect(m_compositor, nullptr, this, nullptr);
    m_compositor = compositor;
    if (m_compositor) {
        m_compositor->registerItem(m_view, this);
        connect(m_compositor, &TerminalCompositor::selectedIdChanged, this, [this] { configure(); updateCursor(); });
    }
    configure(); emit compositorChanged();
}
void TerminalSurfaceItem::configure() {
    if (m_compositor && m_view && isVisible() && m_compositor->selectedId() == m_view->sessionId())
        m_compositor->configure(m_view->sessionId(), int(width()), int(height()));
}
void TerminalSurfaceItem::geometryChange(const QRectF &geometry, const QRectF &old) {
    QQuickItem::geometryChange(geometry, old); configure();
}
void TerminalSurfaceItem::itemChange(ItemChange change, const ItemChangeData &data) {
    QQuickItem::itemChange(change, data);
    if (change == ItemVisibleHasChanged) { configure(); updateCursor(); }
}
void TerminalSurfaceItem::updateCursor() {
    if (m_hovered && isVisible()) setCursor(m_view && m_view->m_cursorKnown ? Qt::BlankCursor : Qt::IBeamCursor);
    else unsetCursor();
}
QSGNode *TerminalSurfaceItem::updatePaintNode(QSGNode *old, UpdatePaintNodeData *) {
    auto *node = static_cast<SurfaceNode *>(old);
    if (!m_view || m_view->m_image.isNull()) { delete node; return nullptr; }
    if (!node || node->view != m_view) {
        delete node; node = new SurfaceNode; node->view = m_view;
        node->terminal = new TextureNode; node->appendChildNode(node->terminal);
    }
    if (node->frameRevision != m_view->m_frameRevision) {
        node->terminal->replace(window()->createTextureFromImage(m_view->m_image));
        node->frameRevision = m_view->m_frameRevision;
        // Draw in the client's configured logical size. Never stretch an old
        // terminal texture to imitate a resize while a configure is in flight.
        node->terminal->setRect(QRectF(QPointF(), m_view->m_logicalSize));
    }
    if (!m_view->m_cursorImage.isNull()) {
        if (!node->cursor) {
            node->cursorOpacity = new QSGOpacityNode; node->appendChildNode(node->cursorOpacity);
            node->cursor = new TextureNode; node->cursorOpacity->appendChildNode(node->cursor);
        }
        if (node->cursorRevision != m_view->m_cursorRevision) {
            node->cursor->replace(window()->createTextureFromImage(m_view->m_cursorImage));
            node->cursorRevision = m_view->m_cursorRevision;
        }
        node->cursor->setRect(QRectF(m_pointer - m_view->m_hotspot, m_view->m_cursorSize));
    }
    if (node->cursorOpacity) node->cursorOpacity->setOpacity(m_hovered && !m_view->m_cursorImage.isNull() ? 1 : 0);
    return node;
}
void TerminalSurfaceItem::mousePressEvent(QMouseEvent *event) {
    if (!m_compositor || !m_view) return;
    m_pointer = event->position(); m_hovered = true; updateCursor();
    m_compositor->focusTerminal(m_view->sessionId());
    m_compositor->interact(m_view->sessionId());
    m_compositor->pointerMove(m_view->sessionId(), m_pointer, event->timestamp());
    m_compositor->pointerButton(event->button(), true, event->timestamp());
    event->accept(); update();
}
void TerminalSurfaceItem::mouseReleaseEvent(QMouseEvent *event) {
    if (m_compositor && m_view) m_compositor->pointerButton(event->button(), false, event->timestamp());
    event->accept();
}
void TerminalSurfaceItem::mouseMoveEvent(QMouseEvent *event) {
    m_pointer = event->position();
    if (m_compositor && m_view) m_compositor->pointerMove(m_view->sessionId(), m_pointer, event->timestamp());
    event->accept(); update();
}
void TerminalSurfaceItem::hoverEnterEvent(QHoverEvent *event) {
    m_hovered = true; hoverMoveEvent(event); updateCursor();
}
void TerminalSurfaceItem::hoverMoveEvent(QHoverEvent *event) {
    m_pointer = event->position();
    if (m_compositor && m_view) m_compositor->pointerMove(m_view->sessionId(), m_pointer, event->timestamp());
    event->accept(); update();
}
void TerminalSurfaceItem::hoverLeaveEvent(QHoverEvent *event) {
    m_hovered = false;
    if (m_compositor) m_compositor->pointerLeave();
    updateCursor(); event->accept(); update();
}
void TerminalSurfaceItem::wheelEvent(QWheelEvent *event) {
    if (m_compositor && m_view) {
        m_compositor->pointerMove(m_view->sessionId(), event->position(), event->timestamp());
        m_compositor->pointerScroll(event->angleDelta(), event->pixelDelta(), event->timestamp());
        m_compositor->interact(m_view->sessionId());
    }
    event->accept();
}
void TerminalSurfaceItem::inputMethodEvent(QInputMethodEvent *event) {
    if (m_compositor && m_view) {
        int cursor = event->preeditString().size();
        for (const auto &attribute : event->attributes()) if (attribute.type == QInputMethodEvent::Cursor) cursor = attribute.start;
        m_compositor->inputMethod(event->preeditString(), cursor, event->commitString());
        if (!event->commitString().isEmpty()) m_compositor->interact(m_view->sessionId());
    }
    event->accept();
}
QVariant TerminalSurfaceItem::inputMethodQuery(Qt::InputMethodQuery query) const {
    if (query == Qt::ImEnabled) return isEnabled() && isVisible();
    if (query == Qt::ImCursorRectangle) return QRectF(m_pointer, QSizeF(1, 20));
    return QQuickItem::inputMethodQuery(query);
}
