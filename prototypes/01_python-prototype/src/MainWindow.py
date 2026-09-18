import os
os.environ["QT_QPA_PLATFORM"] = "windows:wintab"

import sys
import PySide6.QtCore as QtCore
import PySide6.QtGui as QtGui
import PySide6.QtWidgets as QtWidgets

from Brush import Brush, BrushPoint
from Command import CommandRegistry
from Tool import ToolManager
from TimelinePanel import TimelinePanel
from Timeline import Project, Shot, Layer, Keyframe, load_or_create_project

WIDTH, HEIGHT = 1280, 720


# =============================================================================
# Which-Key Popup (Helix-style)
# =============================================================================

class WhichKeyPopup(QtWidgets.QWidget):
    """Floating popup showing available key sequences."""
    
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowFlags(
            QtCore.Qt.FramelessWindowHint | 
            QtCore.Qt.Tool |
            QtCore.Qt.WindowStaysOnTopHint
        )
        self.setAttribute(QtCore.Qt.WA_TranslucentBackground)
        self.setAttribute(QtCore.Qt.WA_ShowWithoutActivating)
        
        self._prefix = ""
        self._items = []  # [(key, description), ...]
        self._title = ""
        
        # Styling
        self._bg_color = QtGui.QColor(30, 30, 30, 240)
        self._border_color = QtGui.QColor(80, 80, 80)
        self._key_color = QtGui.QColor(130, 180, 255)
        self._desc_color = QtGui.QColor(200, 200, 200)
        self._title_color = QtGui.QColor(255, 200, 100)
        self._font = QtGui.QFont("Consolas", 10)
        self._title_font = QtGui.QFont("Consolas", 11, QtGui.QFont.Bold)
        
    def show_prefix(self, prefix):
        """Show options for a sequence prefix like 'o'."""
        self._prefix = prefix
        items = CommandRegistry.get_sequences_for_prefix(prefix)
        if not items:
            self.hide()
            return
        
        # Title based on prefix
        titles = {"o": "Opacity", "s": "Size", "b": "Brush"}
        self._title = titles.get(prefix, f"[{prefix}]")
        self._items = items
        self._update_size()
        self._position_popup()
        self.show()
        self.update()
    
    def show_all_shortcuts(self):
        """Show all available shortcuts."""
        self._prefix = ""
        self._title = "Shortcuts"
        
        data = CommandRegistry.get_all_shortcuts()
        items = []
        
        # Add single keys
        for key_str, desc in data["single"]:
            items.append((key_str, desc))
        
        # Add sequences grouped
        for prefix, seqs in sorted(data["sequences"].items()):
            items.append(("", ""))  # Separator
            items.append((f"[{prefix}]", "─" * 20))
            for suffix, desc in seqs:
                items.append((prefix + suffix, desc))
        
        self._items = items
        self._update_size()
        self._position_popup()
        self.show()
        self.update()
    
    def _update_size(self):
        """Calculate and set widget size based on content."""
        if not self._items:
            return
        
        fm = QtGui.QFontMetrics(self._font)
        tfm = QtGui.QFontMetrics(self._title_font)
        
        # Calculate max widths
        max_key_width = max(fm.horizontalAdvance(k) for k, _ in self._items) if self._items else 0
        max_desc_width = max(fm.horizontalAdvance(d) for _, d in self._items) if self._items else 0
        title_width = tfm.horizontalAdvance(self._title) if self._title else 0
        
        # Layout: padding + key + gap + desc + padding
        padding = 16
        gap = 24
        width = max(
            padding + max_key_width + gap + max_desc_width + padding,
            padding + title_width + padding
        )
        
        # Height: title + items
        line_height = fm.height() + 4
        title_height = tfm.height() + 8 if self._title else 0
        height = padding + title_height + (len(self._items) * line_height) + padding
        
        self.setFixedSize(int(width), int(height))
    
    def _position_popup(self):
        """Position popup at bottom-center of parent."""
        if self.parent():
            parent_rect = self.parent().rect()
            parent_global = self.parent().mapToGlobal(parent_rect.bottomLeft())
            x = parent_global.x() + (parent_rect.width() - self.width()) // 2
            y = parent_global.y() - self.height() - 30  # Above status bar
            self.move(x, y)
    
    def paintEvent(self, event):
        painter = QtGui.QPainter(self)
        painter.setRenderHint(QtGui.QPainter.Antialiasing)
        
        # Background with rounded corners
        rect = self.rect().adjusted(1, 1, -1, -1)
        painter.setBrush(self._bg_color)
        painter.setPen(QtGui.QPen(self._border_color, 1))
        painter.drawRoundedRect(rect, 8, 8)
        
        fm = QtGui.QFontMetrics(self._font)
        tfm = QtGui.QFontMetrics(self._title_font)
        padding = 16
        line_height = fm.height() + 4
        y = padding
        
        # Title
        if self._title:
            painter.setFont(self._title_font)
            painter.setPen(self._title_color)
            painter.drawText(padding, y + tfm.ascent(), self._title)
            y += tfm.height() + 8
        
        # Items
        painter.setFont(self._font)
        for key, desc in self._items:
            if not key and not desc:
                y += line_height // 2  # Separator
                continue
            
            # Key
            painter.setPen(self._key_color)
            painter.drawText(padding, y + fm.ascent(), key)
            
            # Description
            painter.setPen(self._desc_color)
            key_width = fm.horizontalAdvance(key) if key else 0
            painter.drawText(padding + key_width + 24, y + fm.ascent(), desc)
            
            y += line_height
        
        painter.end()


class Canvas(QtWidgets.QWidget):
    def __init__(self, project=None):
        super().__init__()
        self.resize(WIDTH, HEIGHT)
        
        # Project and keyframe system (new Timeline model)
        self.project = project
        self.active_layer_idx = 0  # Which layer we're painting on
        
        # Fallback canvas for standalone mode (no project)
        self._standalone_pixmap = QtGui.QPixmap(self.size())
        self._standalone_pixmap.fill(QtCore.Qt.transparent)
        
        # Composite cache - flattened layers + onion skin
        self._composite_cache = None  # QPixmap
        self._composite_dirty = True  # Needs rebuild
        self._is_drawing = False  # True while stroke in progress
        
        # Navigation 
        self.scale = 1.0
        self.offset = QtCore.QPointF(0, 0)
        self._nav_mode = None
        self._nav_last_point = QtCore.QPointF()
        self._zoom_pivot_canvas = QtCore.QPointF()
        self._zoom_pivot_screen = QtCore.QPointF()
        
        # Tools
        self.tool_manager = ToolManager(self)
        
        # Undo 
        self.undo_stack = []
        self.redo_stack = []
        self.max_undo = 50  
        
        # Cursor preview
        self._cursor_canvas_pos = QtCore.QPointF()
        self._cursor_pressure = 1.0
        self.setMouseTracking(True)
        self.setCursor(QtCore.Qt.BlankCursor)
        self.setFocusPolicy(QtCore.Qt.StrongFocus)
    
    @property
    def canvas_pixmap(self):
        """Get the pixmap to draw on (active layer's current keyframe or standalone)."""
        if self.project and self.project.shot:
            layer = self.project.shot.active_layer
            if layer:
                kf = layer.get_keyframe_at(self.project.shot.current_frame)
                if kf:
                    return kf.get_or_create_pixmap(self.project.canvas_size)
        return self._standalone_pixmap
    
    @canvas_pixmap.setter
    def canvas_pixmap(self, pm):
        """Set the active layer keyframe pixmap (for undo/redo)."""
        if self.project and self.project.shot:
            layer = self.project.shot.active_layer 
            if layer:
                # Need to get or create keyframe at current frame
                frame = self.project.shot.current_frame
                kf = layer.get_keyframe_exact(frame)
                if not kf:
                    # Create a new keyframe
                    kf = layer.insert_keyframe(frame, self.project.canvas_size, duplicate=False)
                kf._pixmap = pm
                kf._dirty = True
                return
        self._standalone_pixmap = pm
    
    def load_frame(self, frame_num: int):
        """Navigate to a frame for editing."""
        if self.project and self.project.shot:
            self.project.shot.goto_frame(frame_num)
        self.undo_stack.clear()
        self.redo_stack.clear()
        
        # Invalidate composite cache on frame change
        self.invalidate_composite()
        
        # Update timeline panel if available
        window = self.window()
        if hasattr(window, 'timeline_panel'):
            window.timeline_panel.update_display()
        
        self.update()
    
    def invalidate_composite(self):
        """Mark composite cache as needing rebuild."""
        self._composite_dirty = True
    
    def _rebuild_composite(self):
        """
        Rebuild the flattened composite of background layers + onion skin.
        
        Cache includes: white bg + onion skin + layers BELOW active layer.
        Active layer and layers above are drawn fresh in paintEvent.
        """
        if not self.project:
            return
        
        size = self.project.canvas_size
        if self._composite_cache is None or self._composite_cache.size() != size:
            self._composite_cache = QtGui.QPixmap(size)
        
        self._composite_cache.fill(QtCore.Qt.white)
        painter = QtGui.QPainter(self._composite_cache)
        
        # Draw onion skin first (behind current frame)
        if self.project.onion_enabled:
            for kf, opacity, tint in self.project.get_onion_keyframes():
                if kf and kf._pixmap:
                    painter.setOpacity(opacity)
                    painter.drawPixmap(0, 0, kf._pixmap)
            painter.setOpacity(1.0)
        
        # Draw layers BELOW active layer (not including active)
        if self.project.shot:
            frame = self.project.shot.current_frame
            active_idx = self.project.shot.active_layer_idx
            for i, layer in enumerate(self.project.shot.layers):
                if i >= active_idx:  # Stop at active layer
                    break
                if not layer.visible:
                    continue
                kf = layer.get_keyframe_at(frame)
                if kf and kf._pixmap:
                    painter.drawPixmap(0, 0, kf._pixmap)
        
        painter.end()
        self._composite_dirty = False
    
    def set_active_layer(self, layer_idx: int):
        """Set which layer to paint on by index."""
        if self.project and self.project.shot:
            if 0 <= layer_idx < len(self.project.shot.layers):
                self.project.shot.active_layer_idx = layer_idx
                self.active_layer_idx = layer_idx
                self.invalidate_composite()  # Layer change needs recomposite
                self.update()

    def event(self, event):
        """Override to catch Tab key before Qt uses it for focus navigation,
        and F10 before Windows uses it for menu activation."""
        if event.type() == QtCore.QEvent.ShortcutOverride:
            # Accept F10/F11/F12 to prevent Windows menu activation
            if event.key() in (QtCore.Qt.Key_F10, QtCore.Qt.Key_F11, QtCore.Qt.Key_F12):
                event.accept()
                return True
        if event.type() == QtCore.QEvent.KeyPress:
            if event.key() == QtCore.Qt.Key_Tab:
                self.keyPressEvent(event)
                return True
        return super().event(event)

    def screen_to_canvas(self, pos):
        """Convert screen coordinates to canvas coordinates."""
        return (pos - self.offset) / self.scale

    def save_undo_state(self):
        """Save current canvas state for undo. Call before modifying canvas."""
        self.undo_stack.append(self.canvas_pixmap.copy())
        # Limit stack size
        while len(self.undo_stack) > self.max_undo:
            self.undo_stack.pop(0)
        # Clear redo stack on new action
        self.redo_stack.clear()

    def tabletEvent(self, event):
        event.accept()  # Prevent conversion to mouse events
        
        screen_pos = event.position()
        canvas_pos = self.screen_to_canvas(screen_pos)
        pressure = event.pressure()
        event_type = event.type()
        button = event.button()  # Which button triggered this event
        
        # Update cursor preview
        self._cursor_canvas_pos = canvas_pos
        self._cursor_pressure = pressure
        
        # Handle navigation with Alt modifier
        if event.modifiers() & QtCore.Qt.AltModifier:
            if event_type == QtCore.QEvent.TabletPress:
                self._nav_last_point = screen_pos
                self._zoom_pivot_canvas = canvas_pos
                self._zoom_pivot_screen = screen_pos
                if button == QtCore.Qt.MiddleButton:
                    self._nav_mode = "pan"
                elif button == QtCore.Qt.RightButton:
                    self._nav_mode = "zoom"
                elif button == QtCore.Qt.LeftButton:
                    self._nav_mode = "pan"  # Pen tip = pan
            elif event_type == QtCore.QEvent.TabletMove and self._nav_mode:
                delta = screen_pos - self._nav_last_point
                if self._nav_mode == "pan":
                    self.offset += delta
                elif self._nav_mode == "zoom":
                    zoom_delta = 1.0 + delta.x() * 0.005
                    new_scale = self.scale * zoom_delta
                    new_scale = max(0.1, min(10.0, new_scale))
                    # Adjust offset so pivot stays under original screen position
                    self.offset = self._zoom_pivot_screen - self._zoom_pivot_canvas * new_scale
                    self.scale = new_scale
                self._nav_last_point = screen_pos
                self.update()
            elif event_type == QtCore.QEvent.TabletRelease:
                self._nav_mode = None
            return
        
        # Drawing - delegate to active tool
        tool = self.tool_manager.active
        if event_type == QtCore.QEvent.TabletPress:
            tool.begin(canvas_pos, pressure)
        elif event_type == QtCore.QEvent.TabletMove:
            tool.move(canvas_pos, pressure)
        elif event_type == QtCore.QEvent.TabletRelease:
            tool.end(canvas_pos, pressure)
        
        # Always update for cursor preview
        self.update()


    def paintEvent(self, event):
        painter = QtGui.QPainter(self)
        
        # Apply canvas transform
        painter.translate(self.offset)
        painter.scale(self.scale, self.scale)
        
        if self.project:
            # Use cached composite for performance
            if self._composite_dirty and not self._is_drawing:
                self._rebuild_composite()
            
            if self._composite_cache:
                # Draw cached composite (white bg + onion + layers below active)
                painter.drawPixmap(0, 0, self._composite_cache)
                
                # Draw active layer and layers above (always fresh)
                if self.project.shot:
                    frame = self.project.shot.current_frame
                    active_idx = self.project.shot.active_layer_idx
                    for i in range(active_idx, len(self.project.shot.layers)):
                        layer = self.project.shot.layers[i]
                        if not layer.visible:
                            continue
                        kf = layer.get_keyframe_at(frame)
                        if kf and kf._pixmap:
                            painter.drawPixmap(0, 0, kf._pixmap)
            else:
                # Fallback: draw layers directly
                painter.fillRect(0, 0, WIDTH, HEIGHT, QtCore.Qt.white)
                if self.project.onion_enabled:
                    self._draw_onion_skin(painter)
                if self.project.shot:
                    self._draw_shot_layers(painter)
        else:
            # Standalone mode
            painter.fillRect(0, 0, WIDTH, HEIGHT, QtCore.Qt.white)
            painter.drawPixmap(0, 0, self._standalone_pixmap)
        
        # Draw tool cursor (in canvas coords, already transformed)
        painter.setRenderHint(QtGui.QPainter.Antialiasing)
        self.tool_manager.active.draw_cursor(
            painter, self._cursor_canvas_pos, self._cursor_pressure
        )
        
        painter.end()
    
    def _draw_shot_layers(self, painter, opacity=1.0, tint=None):
        """Draw all visible layers at current frame."""
        shot = self.project.shot
        if not shot:
            return
        
        frame = shot.current_frame
        
        for layer in shot.layers:
            if not layer.visible:
                continue
            
            kf = layer.get_keyframe_at(frame)
            if not kf or not kf._pixmap:
                continue
            
            if opacity < 1.0 or tint:
                painter.save()
                painter.setOpacity(opacity)
                painter.drawPixmap(0, 0, kf._pixmap)
                painter.restore()
            else:
                painter.drawPixmap(0, 0, kf._pixmap)
    
    def _draw_onion_skin(self, painter):
        """Draw onion skin keyframes."""
        if not self.project:
            return
        
        for kf, opacity, tint in self.project.get_onion_keyframes():
            if kf and kf._pixmap:
                painter.save()
                painter.setOpacity(opacity)
                # Apply tint color overlay
                if tint == "before":
                    # Could add red tint here if desired
                    pass
                elif tint == "after":
                    # Could add green tint here if desired
                    pass
                painter.drawPixmap(0, 0, kf._pixmap)
                painter.restore()

    def mousePressEvent(self, event):
        screen_pos = event.position()
        canvas_pos = self.screen_to_canvas(screen_pos)
        
        # Maya-style navigation with Alt
        if event.modifiers() & QtCore.Qt.AltModifier:
            self._nav_last_point = screen_pos
            self._zoom_pivot_canvas = canvas_pos
            self._zoom_pivot_screen = screen_pos
            if event.button() == QtCore.Qt.MiddleButton:
                self._nav_mode = "pan"
            elif event.button() == QtCore.Qt.RightButton:
                self._nav_mode = "zoom"
            elif event.button() == QtCore.Qt.LeftButton:
                self._nav_mode = "pan"
            return
        
        # Drawing - delegate to tool
        if event.button() == QtCore.Qt.LeftButton:
            self.tool_manager.active.begin(canvas_pos, 1.0)

    def mouseMoveEvent(self, event):
        screen_pos = event.position()
        canvas_pos = self.screen_to_canvas(screen_pos)
        
        # Update cursor preview
        self._cursor_canvas_pos = canvas_pos
        self._cursor_pressure = 1.0
        
        # Navigation
        if self._nav_mode:
            delta = screen_pos - self._nav_last_point
            if self._nav_mode == "pan":
                self.offset += delta
            elif self._nav_mode == "zoom":
                zoom_delta = 1.0 + delta.x() * 0.005
                new_scale = self.scale * zoom_delta
                new_scale = max(0.1, min(10.0, new_scale))
                self.offset = self._zoom_pivot_screen - self._zoom_pivot_canvas * new_scale
                self.scale = new_scale
            self._nav_last_point = screen_pos
            self.update()
            return
        
        # Drawing - delegate to tool
        self.tool_manager.active.move(canvas_pos, 1.0)
        
        # Always update for cursor preview
        self.update()

    def mouseReleaseEvent(self, event):
        if self._nav_mode:
            self._nav_mode = None
            return
        if event.button() == QtCore.Qt.LeftButton:
            self.tool_manager.active.end(self.screen_to_canvas(event.position()), 1.0)

    def keyPressEvent(self, event):
        key = event.key()
        window = self.window()
        
        # Escape closes popup or cancels sequence
        if key == QtCore.Qt.Key_Escape:
            if hasattr(window, 'which_key') and window.which_key.isVisible():
                window.which_key.hide()
                CommandRegistry._pending_sequence = ""
                return
        
        # Tab triggers command mode - handle here to capture it before focus navigation
        if key == QtCore.Qt.Key_Tab:
            if hasattr(window, 'mode') and window.mode == "normal":
                window.mode = "command"
                window.command_buffer = ""
                window.grabKeyboard()
                window.update_status_bar()
                return
        
        # Try registry shortcuts (including sequences like "o1")
        result, error, handled = CommandRegistry.handle_key(event)
        if handled:
            if hasattr(window, 'last_result'):
                window.last_result = error if error else (str(result) if result else "")
                window.update_status_bar()
            return
        
        # No shortcut matched, pass up
        super().keyPressEvent(event)
        
        

class MainWindow(QtWidgets.QMainWindow):
    def __init__(self, project=None):
        super().__init__()
        self.setWindowTitle("Reskia")
        self.resize(WIDTH, HEIGHT)
        self.setFocusPolicy(QtCore.Qt.StrongFocus)  # Allow MainWindow to receive focus
        
        # Project
        self.project = project
        
        # Mode: "normal" or "command"
        self.mode = "normal"
        self.command_buffer = ""
        self.last_result = ""
        
        # Central container with horizontal layout
        container = QtWidgets.QWidget()
        layout = QtWidgets.QHBoxLayout(container)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        
        # Canvas
        self.canvas = Canvas(project)
        layout.addWidget(self.canvas, 1)  # Stretch factor 1
        
        # Timeline panel (right side, togglable) - replaces old LayerPanel
        self.timeline_panel = TimelinePanel()
        self.timeline_panel.set_project(project)
        self.timeline_panel.frame_selected.connect(self._on_timeline_frame_selected)
        self.timeline_panel.layer_selected.connect(self._on_timeline_layer_selected)
        layout.addWidget(self.timeline_panel)
        
        # Alias for backwards compatibility with commands
        self.layer_panel = self.timeline_panel
        
        self.setCentralWidget(container)
        
        # Which-key popup
        self.which_key = WhichKeyPopup(self)
        CommandRegistry.set_sequence_callback(self._on_sequence_change)
        
        # Status bar
        self.status_bar = QtWidgets.QStatusBar()
        self.setStatusBar(self.status_bar)
        
        # Status bar widgets
        self.status_mode = QtWidgets.QLabel()
        self.status_info = QtWidgets.QLabel()
        self.status_shortcuts = QtWidgets.QLabel()
        
        self.status_bar.addWidget(self.status_mode)
        self.status_bar.addWidget(self.status_info, 1)  # Stretch
        self.status_bar.addPermanentWidget(self.status_shortcuts)
        
        # Style the status bar
        self.status_bar.setStyleSheet("""
            QStatusBar { background: #2d2d2d; color: #e0e0e0; }
            QLabel { color: #e0e0e0; padding: 2px 8px; }
        """)
        
        # Set command context
        CommandRegistry.set_context(self)
        
        # Initial status update
        self.update_status_bar()
        
        # Timer for continuous status updates
        self.status_timer = QtCore.QTimer()
        self.status_timer.timeout.connect(self.update_status_bar)
        self.status_timer.start(100)  # Update every 100ms
    
    def _on_sequence_change(self, prefix):
        """Called when a sequence prefix changes."""
        if prefix:
            self.which_key.show_prefix(prefix)
        else:
            self.which_key.hide()
    
    def update_status_bar(self):
        """Update status bar based on current mode."""
        if self.mode == "command":
            self.status_mode.setText("[COMMAND]")
            self.status_mode.setStyleSheet("background: #4a90d9; color: white; font-weight: bold;")
            self.status_info.setText(f"> {self.command_buffer}_")
            self.status_shortcuts.setText("Enter: execute | Esc: cancel | Tab: complete")
        else:
            self.status_mode.setText("[NORMAL]")
            self.status_mode.setStyleSheet("background: #5a5a5a; color: white;")
            
            # Show tool info
            tool = self.canvas.tool_manager.active
            info = tool.get_status_text()
            
            # Add frame info if project loaded
            if self.project and self.project.shot:
                frame_num = self.project.shot.current_frame
                total = self.project.shot.duration
                layer = self.project.shot.active_layer
                layer_name = layer.name if layer else "?"
                onion = " [O]" if self.project.onion_enabled else ""
                info += f" | Frame: {frame_num}/{total} | Layer: {layer_name}{onion}"
            
            info += f" | Zoom: {self.canvas.scale*100:.0f}%"
            if self.last_result:
                info = f"{self.last_result}  |  {info}"
            self.status_info.setText(info)
            
            self.status_shortcuts.setText("[,.] Frames  [P] Onion  [N] Timeline  [?] Help")
    
    def keyPressEvent(self, event):
        key = event.key()
        
        if self.mode == "command":
            self.handle_command_key(event)
        else:
            # Normal mode
            if key == QtCore.Qt.Key_Tab:
                self.mode = "command"
                self.command_buffer = ""
                self.grabKeyboard()  # Intercept ALL keystrokes
                self.update_status_bar()
            else:
                # Forward to canvas
                self.canvas.keyPressEvent(event)
    
    def _on_timeline_frame_selected(self, frame):
        """Handle frame selection from timeline panel."""
        self.canvas.invalidate_composite()  # Frame changed
        self.canvas.update()
        self.update_status_bar()
    
    def _on_timeline_layer_selected(self, layer_idx):
        """Handle layer selection from timeline panel."""
        self.canvas.invalidate_composite()  # Layer changed
        self.canvas.update()
        self.update_status_bar()
    
    def exit_command_mode(self):
        """Exit command mode and restore normal input."""
        self.mode = "normal"
        self.command_buffer = ""
        self.releaseKeyboard()
        self.canvas.setFocus()
        self.update_status_bar()
    
    def handle_command_key(self, event):
        """Handle key press in command mode."""
        key = event.key()
        text = event.text()
        
        if key == QtCore.Qt.Key_Escape:
            # Cancel command mode
            self.last_result = ""
            self.exit_command_mode()
        
        elif key == QtCore.Qt.Key_Return or key == QtCore.Qt.Key_Enter:
            # Execute command
            if self.command_buffer.strip():
                result, error = CommandRegistry.execute(self.command_buffer)
                if error:
                    self.last_result = f"Error: {error}"
                else:
                    self.last_result = str(result) if result else "OK"
            self.exit_command_mode()
        
        elif key == QtCore.Qt.Key_Backspace:
            self.command_buffer = self.command_buffer[:-1]
        
        elif key == QtCore.Qt.Key_Tab:
            # Autocomplete
            completions = CommandRegistry.get_completions(self.command_buffer)
            if len(completions) == 1:
                self.command_buffer = completions[0] + " "
            elif len(completions) > 1:
                self.last_result = "Completions: " + ", ".join(completions)
        
        elif text and text.isprintable():
            self.command_buffer += text
        
        self.update_status_bar()


# load_or_create_project is imported from Timeline module
