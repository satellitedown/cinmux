#pragma once
#include <QQuickItem>
#include <QPointer>
class TerminalView;
class TerminalCompositor;

class TerminalSurfaceItem : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(QObject *view READ view WRITE setView NOTIFY viewChanged)
    Q_PROPERTY(QObject *compositor READ compositor WRITE setCompositor NOTIFY compositorChanged)
public:
    explicit TerminalSurfaceItem(QQuickItem *parent = nullptr);
    QObject *view() const;
    void setView(QObject *view);
    QObject *compositor() const;
    void setCompositor(QObject *compositor);
signals:
    void viewChanged();
    void compositorChanged();
protected:
    QSGNode *updatePaintNode(QSGNode *old, UpdatePaintNodeData *) override;
    void geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry) override;
    void itemChange(ItemChange change, const ItemChangeData &data) override;
    void mousePressEvent(QMouseEvent *event) override;
    void mouseReleaseEvent(QMouseEvent *event) override;
    void mouseMoveEvent(QMouseEvent *event) override;
    void hoverEnterEvent(QHoverEvent *event) override;
    void hoverMoveEvent(QHoverEvent *event) override;
    void hoverLeaveEvent(QHoverEvent *event) override;
    void wheelEvent(QWheelEvent *event) override;
    void inputMethodEvent(QInputMethodEvent *event) override;
    QVariant inputMethodQuery(Qt::InputMethodQuery query) const override;
private:
    void configure();
    void updateCursor();
    QPointer<TerminalView> m_view;
    QPointer<TerminalCompositor> m_compositor;
    QPointF m_pointer;
    bool m_hovered = false;
};
