"""Tool system for Reskia."""

import PySide6.QtCore as QtCore
import PySide6.QtGui as QtGui

from Brush import Brush, BrushPoint


class Tool:
    """Base class for all tools."""
    
    name = "tool"
    icon = None
    
    def __init__(self, canvas):
        self.canvas = canvas
    
    def activate(self):
        """Called when tool becomes active."""
        pass
    
    def deactivate(self):
        """Called when switching to another tool."""
        pass
    
    def begin(self, pos, pressure):
        """Called on pen/mouse down. pos is canvas coords."""
        pass
    
    def move(self, pos, pressure):
        """Called on pen/mouse move while drawing."""
        pass
    
    def end(self, pos, pressure):
        """Called on pen/mouse up."""
        pass
    
    def draw_cursor(self, painter, pos, pressure):
        """Draw tool cursor. painter is already in canvas coords."""
        pass
    
    def get_status_text(self):
        """Return status bar text for this tool."""
        return self.name


class BrushTool(Tool):
    """Standard brush tool for painting."""
    
    name = "brush"
    
    def __init__(self, canvas):
        super().__init__(canvas)
        self.brush = Brush()
        self.last_point = None
        self.drawing = False
        # Stroke buffer for non-accumulation mode
        self._stroke_buffer = None
        self._canvas_backup = None
    
    def begin(self, pos, pressure):
        self.canvas.save_undo_state()
        self.drawing = True
        self.canvas._is_drawing = True  # Signal we're in a stroke
        self.brush.begin_stroke()
        self.last_point = BrushPoint.from_qpointf(pos, pressure)
        
        # For non-accumulation mode, create stroke buffer
        if not self.brush.accumulation:
            # Create transparent buffer same size as canvas
            self._stroke_buffer = QtGui.QPixmap(self.canvas.canvas_pixmap.size())
            self._stroke_buffer.fill(QtCore.Qt.transparent)
            # Keep backup of canvas to composite against
            self._canvas_backup = self.canvas.canvas_pixmap.copy()
    
    def move(self, pos, pressure):
        if not self.drawing:
            return
        
        current = BrushPoint.from_qpointf(pos, pressure)
        
        if self.brush.accumulation:
            # Normal accumulation: paint directly to canvas
            painter = QtGui.QPainter(self.canvas.canvas_pixmap)
            painter.setRenderHint(QtGui.QPainter.Antialiasing)
            painter.setCompositionMode(self.brush.composition_mode)
            self.brush.paint_segment(painter, self.last_point, current)
            painter.end()
        else:
            # Non-accumulation: paint to stroke buffer, then composite
            # Paint to stroke buffer with full opacity (opacity applied during compositing)
            painter = QtGui.QPainter(self._stroke_buffer)
            painter.setRenderHint(QtGui.QPainter.Antialiasing)
            # Use SourceOver for the buffer itself
            painter.setCompositionMode(QtGui.QPainter.CompositionMode_SourceOver)
            self.brush.paint_segment(painter, self.last_point, current, override_opacity=1.0)
            painter.end()
            
            # Composite: restore backup + draw buffer with brush opacity and mode
            self.canvas.canvas_pixmap = self._canvas_backup.copy()
            painter = QtGui.QPainter(self.canvas.canvas_pixmap)
            painter.setRenderHint(QtGui.QPainter.Antialiasing)
            painter.setOpacity(self.brush.opacity)
            painter.setCompositionMode(self.brush.composition_mode)
            painter.drawPixmap(0, 0, self._stroke_buffer)
            painter.end()
        
        self.last_point = current
    
    def end(self, pos, pressure):
        self.drawing = False
        self.last_point = None
        # Clear stroke buffer
        self._stroke_buffer = None
        self._canvas_backup = None
        # End drawing state and rebuild composite
        self.canvas._is_drawing = False
        self.canvas.invalidate_composite()
    
    def draw_cursor(self, painter, pos, pressure):
        size = self.brush.get_size(pressure)
        painter.setPen(QtGui.QPen(QtCore.Qt.black, 1.0 / self.canvas.scale))
        painter.setBrush(QtCore.Qt.NoBrush)
        painter.drawEllipse(pos, size / 2, size / 2)
    
    def get_status_text(self):
        b = self.brush
        mode_str = f" | Mode: {b.mode.capitalize()}" if b.mode != "normal" else ""
        accum_str = " | Accum" if b.accumulation else ""
        return f"Brush | Size: {b.size:.0f} | Opacity: {b.opacity*100:.0f}%{mode_str}{accum_str}"


class EraserTool(Tool):
    """Eraser tool - removes pixels."""
    
    name = "eraser"
    
    def __init__(self, canvas):
        super().__init__(canvas)
        self.brush = Brush()
        self.brush.size = 30.0  # Eraser often bigger
        self.last_point = None
        self.drawing = False
    
    def begin(self, pos, pressure):
        self.canvas.save_undo_state()
        self.drawing = True
        self.canvas._is_drawing = True
        self.brush.begin_stroke()
        self.last_point = BrushPoint.from_qpointf(pos, pressure)
    
    def move(self, pos, pressure):
        if not self.drawing:
            return
        
        current = BrushPoint.from_qpointf(pos, pressure)
        painter = QtGui.QPainter(self.canvas.canvas_pixmap)
        painter.setRenderHint(QtGui.QPainter.Antialiasing)
        # DestinationOut removes pixels where we paint
        painter.setCompositionMode(QtGui.QPainter.CompositionMode_DestinationOut)
        self.brush.paint_segment(painter, self.last_point, current)
        painter.end()
        self.last_point = current
    
    def end(self, pos, pressure):
        self.drawing = False
        self.last_point = None
        self.canvas._is_drawing = False
        self.canvas.invalidate_composite()
    
    def draw_cursor(self, painter, pos, pressure):
        size = self.brush.get_size(pressure)
        painter.setPen(QtGui.QPen(QtCore.Qt.gray, 1.0 / self.canvas.scale))
        painter.setBrush(QtCore.Qt.NoBrush)
        painter.drawEllipse(pos, size / 2, size / 2)
    
    def get_status_text(self):
        b = self.brush
        return f"Eraser | Size: {b.size:.0f}"


class ToolManager:
    """Manages available tools and active tool."""
    
    def __init__(self, canvas):
        self.canvas = canvas
        self.tools = {}
        self.active = None
        self.previous_tool_name = None
        
        # Register default tools
        self.register(BrushTool(canvas))
        self.register(EraserTool(canvas))
        
        # Default to brush
        self.set_tool("brush")
    
    def register(self, tool):
        """Register a tool instance."""
        self.tools[tool.name] = tool
    
    def set_tool(self, name):
        """Switch to a tool by name."""
        if name not in self.tools:
            return False
        
        if self.active:
            self.previous_tool_name = self.active.name
            self.active.deactivate()
        
        self.active = self.tools[name]
        self.active.activate()
        return True
    
    def swap_previous(self):
        """Swap to the previous tool (X key behavior)."""
        if self.previous_tool_name and self.previous_tool_name in self.tools:
            self.set_tool(self.previous_tool_name)
    
    def get_tool(self, name):
        """Get a tool by name."""
        return self.tools.get(name)
