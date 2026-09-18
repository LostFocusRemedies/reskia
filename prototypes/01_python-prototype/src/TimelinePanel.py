"""
TimelinePanel - Vertical timeline with layers and keyframe display.

Layout:
    ┌─────┬─────────────────────┐
    │     │  fg  char  bg       │  <- Layer headers (top)
    ├─────┼─────────────────────┤
    │  1  │  ·    ■    ■        │  <- Each row is a frame
    │  2  │  ·    │    │        │     ■ = keyframe
    │  3  │  ·    │    │        │     │ = hold
    │  4  │  ■    │    │        │     · = empty
    │  5  │  │    ■    │        │
    │ ... │                     │
    └─────┴─────────────────────┘
"""

import PySide6.QtCore as QtCore
import PySide6.QtGui as QtGui
import PySide6.QtWidgets as QtWidgets

from Timeline import Project, Shot, Layer, Keyframe


# Colors
COLOR_BG = QtGui.QColor("#1e1e1e")
COLOR_GRID = QtGui.QColor("#333333")
COLOR_HEADER_BG = QtGui.QColor("#2d2d2d")
COLOR_FRAME_NUM = QtGui.QColor("#888888")
COLOR_CURRENT_FRAME = QtGui.QColor("#4a6fa5")
COLOR_KEYFRAME = QtGui.QColor("#e0e0e0")
COLOR_HOLD = QtGui.QColor("#555555")
COLOR_EMPTY = QtGui.QColor("#333333")
COLOR_ACTIVE_LAYER = QtGui.QColor("#3d5a80")
COLOR_SELECTED_CELL = QtGui.QColor("#ff9f1c")  # Orange highlight for selected cell
COLOR_ONION_BEFORE = QtGui.QColor("#ff6b6b")
COLOR_ONION_AFTER = QtGui.QColor("#6bcb77")

CELL_WIDTH = 24
CELL_HEIGHT = 20
FRAME_NUM_WIDTH = 40
LAYER_HEADER_HEIGHT = 28
GUTTER_WIDTH = 24  # For visibility/lock icons


class TimelinePanel(QtWidgets.QWidget):
    """
    Vertical timeline panel with layer controls and keyframe display.
    
    Replaces the old LayerPanel with a full timeline view.
    """
    
    PANEL_WIDTH = 280
    
    # Signals
    layer_selected = QtCore.Signal(int)  # layer index
    frame_selected = QtCore.Signal(int)  # frame number
    
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedWidth(self.PANEL_WIDTH)
        
        self._project: Project = None
        self._scroll_offset = 0  # Vertical scroll offset in frames
        
        self.setMouseTracking(True)
        self._hover_frame = -1
        self._hover_layer = -1
        
        self._setup_ui()
        self.setVisible(False)  # Start hidden, toggle with N
    
    def _setup_ui(self):
        layout = QtWidgets.QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        
        # Header with title
        header = QtWidgets.QWidget()
        header.setFixedHeight(28)
        header.setStyleSheet("background: #2d2d2d; border-bottom: 1px solid #444;")
        header_layout = QtWidgets.QHBoxLayout(header)
        header_layout.setContentsMargins(8, 0, 8, 0)
        
        title = QtWidgets.QLabel("Timeline")
        title.setStyleSheet("color: #fff; font-weight: bold; font-size: 11px;")
        header_layout.addWidget(title)
        header_layout.addStretch()
        
        close_hint = QtWidgets.QLabel("[N]")
        close_hint.setStyleSheet("color: #666; font-size: 10px;")
        header_layout.addWidget(close_hint)
        
        layout.addWidget(header)
        
        # Timeline canvas (custom painted)
        self._canvas = TimelineCanvas(self)
        layout.addWidget(self._canvas, 1)
        
        # Bottom toolbar
        toolbar = QtWidgets.QWidget()
        toolbar.setFixedHeight(28)
        toolbar.setStyleSheet("background: #2d2d2d; border-top: 1px solid #444;")
        toolbar_layout = QtWidgets.QHBoxLayout(toolbar)
        toolbar_layout.setContentsMargins(8, 0, 8, 0)
        
        # Frame info
        self._frame_label = QtWidgets.QLabel("Frame: 1")
        self._frame_label.setStyleSheet("color: #aaa; font-size: 10px;")
        toolbar_layout.addWidget(self._frame_label)
        
        toolbar_layout.addStretch()
        
        # Duration spinner
        dur_label = QtWidgets.QLabel("Dur:")
        dur_label.setStyleSheet("color: #888; font-size: 10px;")
        toolbar_layout.addWidget(dur_label)
        
        self._duration_spin = QtWidgets.QSpinBox()
        self._duration_spin.setRange(1, 9999)
        self._duration_spin.setValue(24)
        self._duration_spin.setFixedWidth(60)
        self._duration_spin.setStyleSheet("""
            QSpinBox { 
                background: #333; 
                color: #ddd; 
                border: 1px solid #555;
                border-radius: 2px;
                padding: 2px;
            }
        """)
        self._duration_spin.valueChanged.connect(self._on_duration_changed)
        toolbar_layout.addWidget(self._duration_spin)
        
        layout.addWidget(toolbar)
    
    def set_project(self, project: Project):
        """Connect to project."""
        self._project = project
        if project and project.shot:
            self._duration_spin.setValue(project.shot.duration)
        self._canvas.set_project(project)
        self.update_display()
    
    def update_display(self):
        """Refresh the timeline display."""
        if self._project and self._project.shot:
            self._frame_label.setText(f"Frame: {self._project.shot.current_frame}")
            self._duration_spin.setValue(self._project.shot.duration)
        self._canvas.update()
    
    def _on_duration_changed(self, value):
        """Handle duration spinner change."""
        if self._project and self._project.shot:
            self._project.shot.duration = value
            self._canvas.update()
    
    def toggle(self):
        """Toggle visibility."""
        self.setVisible(not self.isVisible())


class TimelineCanvas(QtWidgets.QWidget):
    """
    Custom painted timeline grid showing layers and keyframes.
    """
    
    def __init__(self, parent: TimelinePanel):
        super().__init__(parent)
        self._panel = parent
        self._project: Project = None
        
        self.setMouseTracking(True)
        self._hover_frame = -1
        self._hover_layer = -1
        
        # Selected cell (frame, layer_idx) - for cell-specific operations
        self._selected_frame = -1
        self._selected_layer = -1
        
        # Drag state for moving keyframes
        self._dragging = False
        self._drag_start_frame = -1
        self._drag_start_layer = -1
        self._drag_target_frame = -1
        
        self.setMinimumHeight(200)
        self.setContextMenuPolicy(QtCore.Qt.CustomContextMenu)
        self.customContextMenuRequested.connect(self._show_context_menu)
        
    def set_project(self, project: Project):
        self._project = project
        self.update()
    
    def paintEvent(self, event):
        painter = QtGui.QPainter(self)
        painter.setRenderHint(QtGui.QPainter.Antialiasing)
        
        rect = self.rect()
        painter.fillRect(rect, COLOR_BG)
        
        if not self._project or not self._project.shot:
            painter.setPen(QtGui.QColor("#666"))
            painter.drawText(rect, QtCore.Qt.AlignCenter, "No project loaded")
            return
        
        shot = self._project.shot
        layers = shot.layers
        
        if not layers:
            return
        
        # Calculate layout
        num_layers = len(layers)
        layer_width = CELL_WIDTH
        content_width = FRAME_NUM_WIDTH + GUTTER_WIDTH + (num_layers * layer_width)
        
        # Draw layer headers (top row)
        self._draw_layer_headers(painter, layers)
        
        # Draw frame rows
        y_start = LAYER_HEADER_HEIGHT
        visible_frames = (rect.height() - y_start) // CELL_HEIGHT + 1
        
        for i in range(visible_frames):
            frame = i + 1
            if frame > shot.duration:
                break
            y = y_start + i * CELL_HEIGHT
            self._draw_frame_row(painter, frame, y, layers, shot)
        
        # Draw current frame indicator
        current_y = y_start + (shot.current_frame - 1) * CELL_HEIGHT
        if current_y >= y_start and current_y < rect.height():
            painter.fillRect(0, current_y, FRAME_NUM_WIDTH, CELL_HEIGHT, COLOR_CURRENT_FRAME)
            painter.setPen(QtGui.QColor("#fff"))
            painter.drawText(
                QtCore.QRect(0, current_y, FRAME_NUM_WIDTH, CELL_HEIGHT),
                QtCore.Qt.AlignCenter,
                str(shot.current_frame)
            )
    
    def _draw_layer_headers(self, painter, layers):
        """Draw the layer header row at the top."""
        painter.fillRect(0, 0, self.width(), LAYER_HEADER_HEIGHT, COLOR_HEADER_BG)
        
        # Frame number column header
        painter.setPen(COLOR_FRAME_NUM)
        painter.drawText(
            QtCore.QRect(0, 0, FRAME_NUM_WIDTH, LAYER_HEADER_HEIGHT),
            QtCore.Qt.AlignCenter, "#"
        )
        
        # Gutter column (visibility icons placeholder)
        x = FRAME_NUM_WIDTH
        painter.drawLine(x, 0, x, LAYER_HEADER_HEIGHT)
        x += GUTTER_WIDTH
        
        # Layer columns (from left to right = bottom to top in render order)
        # So bg is leftmost, fg is rightmost
        shot = self._project.shot
        for i, layer in enumerate(layers):
            is_active = (i == shot.active_layer_idx) if shot else False
            
            col_rect = QtCore.QRect(x, 0, CELL_WIDTH, LAYER_HEADER_HEIGHT)
            
            if is_active:
                painter.fillRect(col_rect, COLOR_ACTIVE_LAYER)
            
            # Draw abbreviated layer name vertically or abbreviated
            name = layer.name
            if name == "bg":
                abbrev = "B"
            elif name == "fg":
                abbrev = "F"
            elif name.startswith("char_"):
                abbrev = name[5:6].upper()  # First letter of char name
            else:
                abbrev = name[0].upper()
            
            painter.setPen(QtGui.QColor("#ddd") if is_active else QtGui.QColor("#888"))
            painter.drawText(col_rect, QtCore.Qt.AlignCenter, abbrev)
            
            x += CELL_WIDTH
        
        # Bottom border
        painter.setPen(COLOR_GRID)
        painter.drawLine(0, LAYER_HEADER_HEIGHT - 1, self.width(), LAYER_HEADER_HEIGHT - 1)
    
    def _draw_frame_row(self, painter, frame: int, y: int, layers, shot: Shot):
        """Draw a single frame row."""
        # Frame number
        is_current = (frame == shot.current_frame)
        if not is_current:
            # Draw frame number (only every 5 frames or frame 1)
            if frame == 1 or frame % 5 == 0:
                painter.setPen(COLOR_FRAME_NUM)
                painter.drawText(
                    QtCore.QRect(0, y, FRAME_NUM_WIDTH, CELL_HEIGHT),
                    QtCore.Qt.AlignCenter,
                    str(frame)
                )
        
        # Gutter (could show markers, etc.)
        x = FRAME_NUM_WIDTH
        painter.setPen(COLOR_GRID)
        painter.drawLine(x, y, x, y + CELL_HEIGHT)
        x += GUTTER_WIDTH
        
        # Layer cells
        for i, layer in enumerate(layers):
            cell_rect = QtCore.QRect(x, y, CELL_WIDTH, CELL_HEIGHT)
            
            # Check if this is the selected cell
            is_selected = (frame == self._selected_frame and i == self._selected_layer)
            
            # Check if this is a drag target
            is_drag_target = (self._dragging and 
                              frame == self._drag_target_frame and 
                              i == self._drag_start_layer and
                              frame != self._drag_start_frame)
            
            # Determine cell state
            kf = layer.get_keyframe_exact(frame)
            kf_at = layer.get_keyframe_at(frame)
            
            # Check if this keyframe is being dragged (show as ghost)
            is_being_dragged = (self._dragging and 
                               frame == self._drag_start_frame and 
                               i == self._drag_start_layer)
            
            if is_drag_target:
                # Draw drag target indicator
                self._draw_drag_target_cell(painter, cell_rect)
            elif is_being_dragged:
                # Draw ghost of keyframe being dragged
                self._draw_ghost_keyframe_cell(painter, cell_rect, is_current)
            elif kf:
                # This is a keyframe
                self._draw_keyframe_cell(painter, cell_rect, is_current, is_selected)
            elif kf_at:
                # This is a hold (continuation)
                self._draw_hold_cell(painter, cell_rect, is_current, is_selected)
            else:
                # Empty (before first keyframe)
                self._draw_empty_cell(painter, cell_rect, is_current, is_selected)
            
            # Grid line
            painter.setPen(COLOR_GRID)
            painter.drawLine(x + CELL_WIDTH, y, x + CELL_WIDTH, y + CELL_HEIGHT)
            
            x += CELL_WIDTH
        
        # Horizontal grid line
        painter.setPen(COLOR_GRID)
        painter.drawLine(0, y + CELL_HEIGHT, self.width(), y + CELL_HEIGHT)
    
    def _draw_keyframe_cell(self, painter, rect, is_current, is_selected=False):
        """Draw a cell containing a keyframe (filled circle)."""
        if is_current:
            painter.fillRect(rect, COLOR_CURRENT_FRAME.darker(130))
        
        # Draw selection border
        if is_selected:
            painter.setPen(QtGui.QPen(COLOR_SELECTED_CELL, 2))
            painter.setBrush(QtCore.Qt.NoBrush)
            painter.drawRect(rect.adjusted(1, 1, -1, -1))
        
        # Draw keyframe marker (filled circle)
        center = rect.center()
        radius = 5
        painter.setBrush(COLOR_KEYFRAME)
        painter.setPen(QtCore.Qt.NoPen)
        painter.drawEllipse(center, radius, radius)
    
    def _draw_hold_cell(self, painter, rect, is_current, is_selected=False):
        """Draw a cell that holds the previous keyframe (vertical line)."""
        if is_current:
            painter.fillRect(rect, COLOR_CURRENT_FRAME.darker(130))
        
        # Draw selection border
        if is_selected:
            painter.setPen(QtGui.QPen(COLOR_SELECTED_CELL, 2))
            painter.setBrush(QtCore.Qt.NoBrush)
            painter.drawRect(rect.adjusted(1, 1, -1, -1))
        
        # Draw hold indicator (vertical line)
        center_x = rect.center().x()
        painter.setPen(QtGui.QPen(COLOR_HOLD, 2))
        painter.drawLine(center_x, rect.top() + 2, center_x, rect.bottom() - 2)
    
    def _draw_empty_cell(self, painter, rect, is_current, is_selected=False):
        """Draw an empty cell (small dot)."""
        if is_current:
            painter.fillRect(rect, COLOR_CURRENT_FRAME.darker(130))
        
        # Draw selection border
        if is_selected:
            painter.setPen(QtGui.QPen(COLOR_SELECTED_CELL, 2))
            painter.setBrush(QtCore.Qt.NoBrush)
            painter.drawRect(rect.adjusted(1, 1, -1, -1))
        
        # Draw small dot
        center = rect.center()
        painter.setBrush(COLOR_EMPTY)
        painter.setPen(QtCore.Qt.NoPen)
        painter.drawEllipse(center, 2, 2)
    
    def _draw_drag_target_cell(self, painter, rect):
        """Draw a cell showing the drag target location."""
        # Highlight background
        painter.fillRect(rect, QtGui.QColor("#ffcc00").darker(150))
        
        # Draw ghost keyframe marker (hollow circle)
        center = rect.center()
        radius = 5
        painter.setBrush(QtCore.Qt.NoBrush)
        painter.setPen(QtGui.QPen(COLOR_SELECTED_CELL, 2))
        painter.drawEllipse(center, radius, radius)
    
    def _draw_ghost_keyframe_cell(self, painter, rect, is_current):
        """Draw a ghost of the keyframe being dragged (faded)."""
        if is_current:
            painter.fillRect(rect, COLOR_CURRENT_FRAME.darker(130))
        
        # Draw faded keyframe marker
        center = rect.center()
        radius = 5
        ghost_color = QtGui.QColor(COLOR_KEYFRAME)
        ghost_color.setAlpha(80)
        painter.setBrush(ghost_color)
        painter.setPen(QtCore.Qt.NoPen)
        painter.drawEllipse(center, radius, radius)
    
    def mousePressEvent(self, event):
        """Handle click to select frame/layer, or start keyframe drag."""
        if not self._project or not self._project.shot:
            return
        
        pos = event.position()
        x, y = pos.x(), pos.y()
        
        shot = self._project.shot
        layers = shot.layers
        
        # Check if clicked in frame area
        if y > LAYER_HEADER_HEIGHT:
            frame = int((y - LAYER_HEADER_HEIGHT) / CELL_HEIGHT) + 1
            frame = max(1, min(frame, shot.duration))
            
            # Check if clicked on a layer column
            layer_x_start = FRAME_NUM_WIDTH + GUTTER_WIDTH
            layer_idx = -1
            if x >= layer_x_start:
                layer_idx = int((x - layer_x_start) / CELL_WIDTH)
                if not (0 <= layer_idx < len(layers)):
                    layer_idx = -1
            
            if layer_idx >= 0:
                layer = layers[layer_idx]
                # Check if clicking on a keyframe - start drag
                if layer.is_keyframe_at(frame) and event.button() == QtCore.Qt.LeftButton:
                    self._dragging = True
                    self._drag_start_frame = frame
                    self._drag_start_layer = layer_idx
                    self._drag_target_frame = frame
                
                shot.active_layer_idx = layer_idx
                self._selected_frame = frame
                self._selected_layer = layer_idx
            
            # Navigate to frame
            shot.goto_frame(frame)
            self._panel.update_display()
            self._panel.frame_selected.emit(frame)
        
        # Check if clicked in layer header
        elif y < LAYER_HEADER_HEIGHT:
            layer_x_start = FRAME_NUM_WIDTH + GUTTER_WIDTH
            if x >= layer_x_start:
                layer_idx = int((x - layer_x_start) / CELL_WIDTH)
                if 0 <= layer_idx < len(layers):
                    shot.active_layer_idx = layer_idx
                    self._panel.update_display()
                    self._panel.layer_selected.emit(layer_idx)
    
    def mouseMoveEvent(self, event):
        """Handle mouse move for drag preview."""
        if not self._project or not self._project.shot:
            return
        
        if self._dragging:
            pos = event.position()
            y = pos.y()
            
            if y > LAYER_HEADER_HEIGHT:
                shot = self._project.shot
                frame = int((y - LAYER_HEADER_HEIGHT) / CELL_HEIGHT) + 1
                frame = max(1, min(frame, shot.duration))
                
                if frame != self._drag_target_frame:
                    self._drag_target_frame = frame
                    self.update()  # Redraw to show drag preview
    
    def mouseReleaseEvent(self, event):
        """Handle mouse release to complete drag."""
        if self._dragging:
            if self._drag_target_frame != self._drag_start_frame:
                # Move the keyframe
                shot = self._project.shot
                layer = shot.layers[self._drag_start_layer]
                layer.move_keyframe(self._drag_start_frame, self._drag_target_frame)
                
                # Update selected cell to new position
                self._selected_frame = self._drag_target_frame
                shot.goto_frame(self._drag_target_frame)
                
                self._panel.update_display()
                self._panel.frame_selected.emit(self._drag_target_frame)
            
            self._dragging = False
            self._drag_start_frame = -1
            self._drag_start_layer = -1
            self._drag_target_frame = -1
            self.update()
    
    def _get_cell_at(self, pos):
        """Get (frame, layer_idx) at position, or (-1, -1) if not on a cell."""
        if not self._project or not self._project.shot:
            return (-1, -1)
        
        x, y = pos.x(), pos.y()
        shot = self._project.shot
        layers = shot.layers
        
        if y <= LAYER_HEADER_HEIGHT:
            return (-1, -1)
        
        frame = int((y - LAYER_HEADER_HEIGHT) / CELL_HEIGHT) + 1
        frame = max(1, min(frame, shot.duration))
        
        layer_x_start = FRAME_NUM_WIDTH + GUTTER_WIDTH
        if x < layer_x_start:
            return (frame, -1)
        
        layer_idx = int((x - layer_x_start) / CELL_WIDTH)
        if 0 <= layer_idx < len(layers):
            return (frame, layer_idx)
        
        return (frame, -1)
    
    def _show_context_menu(self, pos):
        """Show right-click context menu for cell operations."""
        if not self._project or not self._project.shot:
            return
        
        frame, layer_idx = self._get_cell_at(pos)
        if frame < 1 or layer_idx < 0:
            return
        
        shot = self._project.shot
        layer = shot.layers[layer_idx]
        
        # Update selection to right-clicked cell
        shot.goto_frame(frame)
        shot.active_layer_idx = layer_idx
        self._selected_frame = frame
        self._selected_layer = layer_idx
        self._panel.update_display()
        self._panel.frame_selected.emit(frame)
        
        # Check cell state
        is_keyframe = layer.is_keyframe_at(frame)
        has_content = layer.get_keyframe_at(frame) is not None
        
        menu = QtWidgets.QMenu(self)
        menu.setStyleSheet("""
            QMenu { 
                background: #2d2d2d; 
                color: #ddd; 
                border: 1px solid #555;
            }
            QMenu::item:selected { background: #4a6fa5; }
            QMenu::separator { background: #444; height: 1px; margin: 4px 8px; }
        """)
        
        # Keyframe operations
        if is_keyframe:
            menu.addAction("Delete Keyframe (kx)", self._ctx_delete_keyframe)
            menu.addAction("Clear Keyframe (kc)", self._ctx_clear_keyframe)
            menu.addAction("Copy Keyframe (ky)", self._ctx_copy_keyframe)
        else:
            menu.addAction("Insert Keyframe (ki)", self._ctx_insert_keyframe)
            menu.addAction("Insert Blank Keyframe (kk)", self._ctx_insert_blank_keyframe)
        
        # Paste if clipboard has content
        from Command import _keyframe_clipboard
        if _keyframe_clipboard is not None:
            menu.addAction("Paste Keyframe (kp)", self._ctx_paste_keyframe)
        
        menu.addSeparator()
        
        # Frame operations (affect all layers)
        menu.addAction("Insert Frame (kf)", self._ctx_insert_frame)
        menu.addAction("Remove Frame (kr)", self._ctx_remove_frame)
        
        menu.addSeparator()
        
        # Layer operations
        menu.addAction("Add Layer Above (ln)", self._ctx_add_layer)
        menu.addAction("Delete Layer (lx)", self._ctx_delete_layer)
        menu.addAction("Rename Layer... (lr)", self._ctx_rename_layer)
        
        menu.addSeparator()
        
        # Layer reorder
        shot = self._project.shot
        if self._selected_layer < len(shot.layers) - 1:
            menu.addAction("Move Layer Up (lk)", self._ctx_layer_up)
        if self._selected_layer > 0:
            menu.addAction("Move Layer Down (lj)", self._ctx_layer_down)
        
        menu.addSeparator()
        
        # Layer visibility/lock
        layer = shot.layers[self._selected_layer]
        vis_text = "Hide Layer (lv)" if layer.visible else "Show Layer (lv)"
        lock_text = "Unlock Layer (ll)" if layer.locked else "Lock Layer (ll)"
        menu.addAction(vis_text, self._ctx_toggle_visibility)
        menu.addAction(lock_text, self._ctx_toggle_lock)
        
        menu.exec(self.mapToGlobal(pos))
    
    def _ctx_insert_keyframe(self):
        """Insert keyframe at selected cell (F6 style)."""
        if self._selected_frame < 1 or self._selected_layer < 0:
            return
        shot = self._project.shot
        layer = shot.layers[self._selected_layer]
        layer.insert_keyframe(self._selected_frame, self._project.canvas_size, duplicate=True)
        self._panel.update_display()
        self._panel.frame_selected.emit(self._selected_frame)
    
    def _ctx_insert_blank_keyframe(self):
        """Insert blank keyframe at selected cell (F7 style)."""
        if self._selected_frame < 1 or self._selected_layer < 0:
            return
        shot = self._project.shot
        layer = shot.layers[self._selected_layer]
        layer.insert_keyframe(self._selected_frame, self._project.canvas_size, duplicate=False)
        self._panel.update_display()
        self._panel.frame_selected.emit(self._selected_frame)
    
    def _ctx_delete_keyframe(self):
        """Delete keyframe at selected cell."""
        if self._selected_frame < 1 or self._selected_layer < 0:
            return
        shot = self._project.shot
        layer = shot.layers[self._selected_layer]
        layer.delete_keyframe(self._selected_frame)
        self._panel.update_display()
        self._panel.frame_selected.emit(self._selected_frame)
    
    def _ctx_clear_keyframe(self):
        """Clear keyframe content (make transparent)."""
        if self._selected_frame < 1 or self._selected_layer < 0:
            return
        shot = self._project.shot
        layer = shot.layers[self._selected_layer]
        kf = layer.get_keyframe_exact(self._selected_frame)
        if kf:
            kf._pixmap = QtGui.QPixmap(self._project.canvas_size)
            kf._pixmap.fill(QtCore.Qt.transparent)
            kf._dirty = True
        self._panel.update_display()
        self._panel.frame_selected.emit(self._selected_frame)
    
    def _ctx_add_layer(self):
        """Add a new layer above current."""
        shot = self._project.shot
        # Generate unique name
        n = len(shot.layers) + 1
        name = f"layer_{n}"
        while shot.get_layer(name):
            n += 1
            name = f"layer_{n}"
        
        idx = self._selected_layer + 1 if self._selected_layer >= 0 else len(shot.layers)
        layer = shot.add_layer(name, index=idx)
        layer.insert_keyframe(1, self._project.canvas_size, duplicate=False)
        shot.active_layer_idx = idx
        self._selected_layer = idx
        # Invalidate composite and update
        window = self.window()
        if hasattr(window, 'canvas'):
            window.canvas.invalidate_composite()
        self._panel.update_display()
        self._panel.layer_selected.emit(idx)
    
    def _ctx_delete_layer(self):
        """Delete selected layer."""
        shot = self._project.shot
        if len(shot.layers) <= 1:
            return  # Can't delete last layer
        
        idx = self._selected_layer if self._selected_layer >= 0 else shot.active_layer_idx
        shot.layers.pop(idx)
        if shot.active_layer_idx >= len(shot.layers):
            shot.active_layer_idx = len(shot.layers) - 1
        self._selected_layer = shot.active_layer_idx
        # Invalidate composite
        window = self.window()
        if hasattr(window, 'canvas'):
            window.canvas.invalidate_composite()
        self._panel.update_display()
        self._panel.layer_selected.emit(self._selected_layer)
    
    def _ctx_rename_layer(self):
        """Rename selected layer."""
        shot = self._project.shot
        idx = self._selected_layer if self._selected_layer >= 0 else shot.active_layer_idx
        layer = shot.layers[idx]
        
        new_name, ok = QtWidgets.QInputDialog.getText(
            self, "Rename Layer", "New name:", text=layer.name
        )
        if ok and new_name:
            layer.name = new_name
            self._panel.update_display()
    
    def _ctx_copy_keyframe(self):
        """Copy keyframe to clipboard."""
        import Command
        if self._selected_frame < 1 or self._selected_layer < 0:
            return
        shot = self._project.shot
        layer = shot.layers[self._selected_layer]
        copied = layer.copy_keyframe(self._selected_frame)
        if copied:
            Command._keyframe_clipboard = copied
    
    def _ctx_paste_keyframe(self):
        """Paste keyframe from clipboard."""
        import Command
        if self._selected_frame < 1 or self._selected_layer < 0:
            return
        if Command._keyframe_clipboard is None:
            return
        shot = self._project.shot
        layer = shot.layers[self._selected_layer]
        layer.paste_keyframe(self._selected_frame, Command._keyframe_clipboard)
        self._panel.update_display()
        self._panel.frame_selected.emit(self._selected_frame)
    
    def _ctx_insert_frame(self):
        """Insert a frame at current position, shifting all keyframes down."""
        if self._selected_frame < 1:
            return
        shot = self._project.shot
        shot.insert_frame_at(self._selected_frame)
        self._panel.update_display()
        self._panel.frame_selected.emit(self._selected_frame)
    
    def _ctx_remove_frame(self):
        """Remove frame at current position, shifting all keyframes up."""
        if self._selected_frame < 1:
            return
        shot = self._project.shot
        shot.remove_frame_at(self._selected_frame)
        # Adjust selection if needed
        if self._selected_frame > shot.duration:
            self._selected_frame = shot.duration
        self._panel.update_display()
        self._panel.frame_selected.emit(self._selected_frame)
    
    def _ctx_layer_up(self):
        """Move selected layer up (toward front)."""
        if self._selected_layer < 0:
            return
        shot = self._project.shot
        idx = self._selected_layer
        if idx >= len(shot.layers) - 1:
            return
        shot.layers[idx], shot.layers[idx + 1] = shot.layers[idx + 1], shot.layers[idx]
        shot.active_layer_idx = idx + 1
        self._selected_layer = idx + 1
        window = self.window()
        if hasattr(window, 'canvas'):
            window.canvas.invalidate_composite()
        self._panel.update_display()
        self._panel.layer_selected.emit(idx + 1)
    
    def _ctx_layer_down(self):
        """Move selected layer down (toward back)."""
        if self._selected_layer < 0:
            return
        shot = self._project.shot
        idx = self._selected_layer
        if idx <= 0:
            return
        shot.layers[idx], shot.layers[idx - 1] = shot.layers[idx - 1], shot.layers[idx]
        shot.active_layer_idx = idx - 1
        self._selected_layer = idx - 1
        window = self.window()
        if hasattr(window, 'canvas'):
            window.canvas.invalidate_composite()
        self._panel.update_display()
        self._panel.layer_selected.emit(idx - 1)
    
    def _ctx_toggle_visibility(self):
        """Toggle selected layer visibility."""
        if self._selected_layer < 0:
            return
        shot = self._project.shot
        layer = shot.layers[self._selected_layer]
        layer.visible = not layer.visible
        window = self.window()
        if hasattr(window, 'canvas'):
            window.canvas.invalidate_composite()
        self._panel.update_display()
    
    def _ctx_toggle_lock(self):
        """Toggle selected layer lock."""
        if self._selected_layer < 0:
            return
        shot = self._project.shot
        layer = shot.layers[self._selected_layer]
        layer.locked = not layer.locked
        self._panel.update_display()
    
    def wheelEvent(self, event):
        """Handle scroll wheel for timeline scrolling."""
        # For now, just update (could implement scrolling later)
        delta = event.angleDelta().y()
        # Could scroll through frames here
        super().wheelEvent(event)
