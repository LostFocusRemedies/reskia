import math
import PySide6.QtCore as QtCore
import PySide6.QtGui as QtGui


class BrushPoint:
    """A single input point with all its data."""
    __slots__ = ('x', 'y', 'pressure')
    
    def __init__(self, x, y, pressure=1.0):
        self.x = x
        self.y = y
        self.pressure = pressure
    
    def to_qpointf(self):
        return QtCore.QPointF(self.x, self.y)
    
    @classmethod
    def from_qpointf(cls, point, pressure=1.0):
        return cls(point.x(), point.y(), pressure)


# Composition modes mapping
COMPOSITION_MODES = {
    "normal": QtGui.QPainter.CompositionMode_SourceOver,
    "behind": QtGui.QPainter.CompositionMode_DestinationOver,
    "multiply": QtGui.QPainter.CompositionMode_Multiply,
    "overlay": QtGui.QPainter.CompositionMode_Overlay,
    "erase": QtGui.QPainter.CompositionMode_DestinationOut,
}

COMPOSITION_MODE_NAMES = list(COMPOSITION_MODES.keys())


class Brush:
    """Brush settings and rendering logic."""
    
    def __init__(self):
        # Core settings
        self.size = 10.0
        self.color = QtGui.QColor(0, 0, 0)
        self.opacity = 1.0
        
        # Composition mode
        self.mode = "normal"  # normal, behind, multiply, overlay
        
        # Accumulation: if True, paint builds up when going over same area in one stroke
        self.accumulation = True
        
        # Dynamics: how pressure affects output (0.0 = no effect, 1.0 = full effect)
        self.pressure_affects_size = 1.0
        self.pressure_affects_opacity = 0.0
        
        # Spacing: distance between stamps as fraction of brush size (0 = continuous line)
        self.spacing = 0.0  # 0 means use drawLine, >0 means stamp-based
        
        # Internal state for spacing
        self._spacing_accumulator = 0.0
    
    @property
    def composition_mode(self):
        """Get Qt composition mode for current mode."""
        return COMPOSITION_MODES.get(self.mode, QtGui.QPainter.CompositionMode_SourceOver)
    
    def cycle_mode(self, direction=1):
        """Cycle to next/previous composition mode."""
        # Don't include erase in brush cycling
        brush_modes = ["normal", "behind", "multiply", "overlay"]
        try:
            idx = brush_modes.index(self.mode)
        except ValueError:
            idx = 0
        idx = (idx + direction) % len(brush_modes)
        self.mode = brush_modes[idx]
        return self.mode
    
    def begin_stroke(self):
        """Called when a new stroke begins."""
        self._spacing_accumulator = 0.0
    
    def get_size(self, pressure):
        """Calculate size based on pressure."""
        min_size = self.size * (1.0 - self.pressure_affects_size)
        return min_size + (self.size - min_size) * pressure
    
    def get_opacity(self, pressure):
        """Calculate opacity based on pressure."""
        min_opacity = self.opacity * (1.0 - self.pressure_affects_opacity)
        return min_opacity + (self.opacity - min_opacity) * pressure
    
    def paint_segment(self, painter, p1, p2, override_opacity=None):
        """
        Paint from p1 to p2. Both are BrushPoints.
        
        Args:
            override_opacity: If set, use this opacity instead of brush opacity.
                              Used for non-accumulation mode where opacity is
                              applied during final compositing.
        """
        # Interpolate pressure
        avg_pressure = (p1.pressure + p2.pressure) / 2.0
        
        size = self.get_size(avg_pressure)
        
        if override_opacity is not None:
            opacity = override_opacity
        else:
            opacity = self.get_opacity(avg_pressure)
        
        color = QtGui.QColor(self.color)
        color.setAlphaF(opacity)
        
        if self.spacing <= 0:
            # Simple line mode
            pen = QtGui.QPen(color, size,
                            QtCore.Qt.SolidLine, QtCore.Qt.RoundCap, QtCore.Qt.RoundJoin)
            painter.setPen(pen)
            painter.drawLine(p1.to_qpointf(), p2.to_qpointf())
        else:
            # Stamp mode with spacing
            self._paint_stamped(painter, p1, p2, size, color)
    
    def _paint_stamped(self, painter, p1, p2, size, color):
        """Paint stamps along the segment with proper spacing."""
        dx = p2.x - p1.x
        dy = p2.y - p1.y
        dist = math.sqrt(dx * dx + dy * dy)
        
        if dist < 0.001:
            return
        
        step = self.spacing * self.size
        if step < 1:
            step = 1
        
        # Normalize direction
        nx, ny = dx / dist, dy / dist
        
        # Start from accumulated remainder
        t = self._spacing_accumulator
        
        painter.setPen(QtCore.Qt.NoPen)
        painter.setBrush(QtGui.QBrush(color))
        
        while t < dist:
            # Interpolate position and pressure
            ratio = t / dist
            x = p1.x + dx * ratio
            y = p1.y + dy * ratio
            pressure = p1.pressure + (p2.pressure - p1.pressure) * ratio
            
            stamp_size = self.get_size(pressure)
            painter.drawEllipse(QtCore.QPointF(x, y), stamp_size / 2, stamp_size / 2)
            t += step
        
        # Store remainder for next segment
        self._spacing_accumulator = t - dist



