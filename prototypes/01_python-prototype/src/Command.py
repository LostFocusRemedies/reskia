import PySide6.QtCore as QtCore
import PySide6.QtGui as QtGui
import PySide6.QtWidgets as QtWidgets


# =============================================================================
# Command System
# =============================================================================

# Modifier string → Qt modifier flag
_MODIFIER_MAP = {
    "ctrl": QtCore.Qt.ControlModifier,
    "alt": QtCore.Qt.AltModifier,
    "shift": QtCore.Qt.ShiftModifier,
    "meta": QtCore.Qt.MetaModifier,
}

# Key string → Qt key code (common ones)
_KEY_MAP = {
    **{chr(i): getattr(QtCore.Qt, f"Key_{chr(i).upper()}") for i in range(ord('a'), ord('z')+1)},
    **{str(i): getattr(QtCore.Qt, f"Key_{i}") for i in range(10)},
    "[": QtCore.Qt.Key_BracketLeft,
    "]": QtCore.Qt.Key_BracketRight,
    "-": QtCore.Qt.Key_Minus,
    "=": QtCore.Qt.Key_Equal,
    "+": QtCore.Qt.Key_Plus,
    "?": QtCore.Qt.Key_Question,
    "/": QtCore.Qt.Key_Slash,
    ",": QtCore.Qt.Key_Comma,
    ".": QtCore.Qt.Key_Period,
    "<": QtCore.Qt.Key_Less,
    ">": QtCore.Qt.Key_Greater,
    "space": QtCore.Qt.Key_Space,
    "enter": QtCore.Qt.Key_Return,
    "return": QtCore.Qt.Key_Return,
    "esc": QtCore.Qt.Key_Escape,
    "escape": QtCore.Qt.Key_Escape,
    "tab": QtCore.Qt.Key_Tab,
    "backspace": QtCore.Qt.Key_Backspace,
    "delete": QtCore.Qt.Key_Delete,
    "f1": QtCore.Qt.Key_F1, "f2": QtCore.Qt.Key_F2, "f3": QtCore.Qt.Key_F3,
    "f4": QtCore.Qt.Key_F4, "f5": QtCore.Qt.Key_F5, "f6": QtCore.Qt.Key_F6,
    "f7": QtCore.Qt.Key_F7, "f8": QtCore.Qt.Key_F8, "f9": QtCore.Qt.Key_F9,
    "f10": QtCore.Qt.Key_F10, "f11": QtCore.Qt.Key_F11, "f12": QtCore.Qt.Key_F12,
}


# Keys that require Shift to type (so we implicitly add ShiftModifier)
# _SHIFTED_KEYS = {"?", "+"}
_SHIFTED_KEYS = {"?"}


def parse_shortcut(shortcut_str):
    """Parse 'Ctrl+S' → (Qt.ControlModifier, Qt.Key_S).
    
    Returns (modifiers_combined, key_code) or None if invalid.
    """
    # Handle bare "+" or "-" before splitting
    shortcut_lower = shortcut_str.strip().lower()
    if shortcut_lower in _KEY_MAP:
        key = _KEY_MAP[shortcut_lower]
        modifiers = QtCore.Qt.NoModifier
        if shortcut_lower in _SHIFTED_KEYS:
            modifiers |= QtCore.Qt.ShiftModifier
        return (modifiers, key)
    
    parts = [p.strip().lower() for p in shortcut_str.split("+")]
    modifiers = QtCore.Qt.NoModifier
    key = None
    original_char = None
    
    for part in parts:
        if part in _MODIFIER_MAP:
            modifiers |= _MODIFIER_MAP[part]
        elif part in _KEY_MAP:
            key = _KEY_MAP[part]
            original_char = part
        else:
            return None  # Unknown part
    
    if key is None:
        return None
    
    # Add implicit Shift for keys that require it
    if original_char in _SHIFTED_KEYS:
        modifiers |= QtCore.Qt.ShiftModifier
    
    return (modifiers, key)


def event_to_combo(event):
    """Convert QKeyEvent → (modifiers, key)."""
    return (event.modifiers() & ~QtCore.Qt.KeypadModifier, event.key())


class CommandRegistry:
    """Registry for executable commands. Emacs-style command system."""
    
    _commands = {}
    _shortcuts = {}  # (modifiers, key) → command_name
    _sequences = {}  # "o1" → command_name (multi-key shortcuts)
    _pending_sequence = ""  # Current partial sequence
    _context = None  # Will hold reference to MainWindow
    _on_sequence_change = None  # Callback when pending sequence changes
    
    @classmethod
    def set_context(cls, context):
        """Set the application context (MainWindow) for commands to access."""
        cls._context = context
    
    @classmethod
    def set_sequence_callback(cls, callback):
        """Set callback for when pending sequence changes. callback(prefix_or_None)"""
        cls._on_sequence_change = callback
    
    @classmethod
    def _notify_sequence_change(cls):
        """Notify that pending sequence changed."""
        if cls._on_sequence_change:
            cls._on_sequence_change(cls._pending_sequence if cls._pending_sequence else None)
    
    @classmethod
    def register(cls, name, func, description="", shortcuts=None):
        """Register a command.
        
        Args:
            name: Command name (e.g., "set", "brush.size")
            func: Callable that receives (context, *args)
            description: Human-readable description
            shortcuts: List of keyboard shortcuts (e.g., ["Ctrl+S", "Q", "o1"])
        """
        shortcuts = shortcuts or []
        cls._commands[name] = {
            "func": func,
            "desc": description,
            "shortcuts": shortcuts
        }
        # Register shortcut → command lookup
        for sc in shortcuts:
            if len(sc) > 1 and "+" not in sc:
                # Multi-key sequence like "o1", "gg"
                cls._sequences[sc.lower()] = name
            else:
                # Single key or modifier combo
                parsed = parse_shortcut(sc)
                if parsed:
                    cls._shortcuts[parsed] = name
    
    @classmethod
    def register_sequence(cls, prefix, suffix, func, description=""):
        """Register a sequence shortcut like 'o1' (prefix='o', suffix='1').
        
        This is a convenience for registering sequences with nice display in which-key.
        """
        seq = prefix + suffix
        name = f"_seq_{seq}"
        cls._commands[name] = {
            "func": func,
            "desc": description,
            "shortcuts": [seq]
        }
        cls._sequences[seq.lower()] = name
    
    @classmethod
    def handle_key(cls, event):
        """Handle a key event. Returns (result, error, handled).
        
        handled=True means the key was consumed (matched or pending sequence).
        handled=False means the key should be processed normally.
        """
        text = event.text().lower()
        old_pending = cls._pending_sequence
        
        # Build sequence
        if text and text.isprintable() and not (event.modifiers() & (QtCore.Qt.ControlModifier | QtCore.Qt.AltModifier)):
            test_seq = cls._pending_sequence + text
            
            # Check for exact match
            if test_seq in cls._sequences:
                cls._pending_sequence = ""
                cls._notify_sequence_change()
                name = cls._sequences[test_seq]
                result, error = cls.execute_direct(name)
                return result, error, True
            
            # Check if it's a prefix of any sequence
            is_prefix = any(seq.startswith(test_seq) for seq in cls._sequences)
            if is_prefix:
                cls._pending_sequence = test_seq
                cls._notify_sequence_change()
                return f"[{test_seq}...]", None, True
            
            # No match - if we had a pending sequence, it's invalid
            if cls._pending_sequence:
                cls._pending_sequence = ""
                cls._notify_sequence_change()
                # Fall through to try as single key
        
        # Clear any pending sequence for modifier keys
        if event.modifiers() & (QtCore.Qt.ControlModifier | QtCore.Qt.AltModifier):
            if cls._pending_sequence:
                cls._pending_sequence = ""
                cls._notify_sequence_change()
        
        # Try single-key/modifier shortcut
        combo = event_to_combo(event)
        if combo in cls._shortcuts:
            name = cls._shortcuts[combo]
            result, error = cls.execute_direct(name)
            return result, error, True
        
        return None, None, False
    
    @classmethod
    def get_sequences_for_prefix(cls, prefix):
        """Get all sequences that start with prefix and their descriptions.
        
        Returns: list of (suffix, description) tuples
        """
        results = []
        for seq, cmd_name in cls._sequences.items():
            if seq.startswith(prefix) and len(seq) > len(prefix):
                suffix = seq[len(prefix):]
                cmd = cls._commands.get(cmd_name, {})
                desc = cmd.get("desc", cmd_name)
                results.append((suffix, desc))
        return sorted(results)
    
    @classmethod
    def get_all_shortcuts(cls):
        """Get all shortcuts grouped by type.
        
        Returns dict: {
            "single": [(key_str, description), ...],
            "sequences": {prefix: [(suffix, desc), ...]},
        }
        """
        # Single keys
        single = []
        for combo, cmd_name in cls._shortcuts.items():
            modifiers, key = combo
            # Convert back to string  
            key_str = ""
            if modifiers & QtCore.Qt.ControlModifier:
                key_str += "Ctrl+"
            if modifiers & QtCore.Qt.AltModifier:
                key_str += "Alt+"
            if modifiers & QtCore.Qt.ShiftModifier:
                key_str += "Shift+"
            # Get key name
            for name, code in _KEY_MAP.items():
                if code == key:
                    key_str += name.upper() if len(name) == 1 else name
                    break
            cmd = cls._commands.get(cmd_name, {})
            single.append((key_str, cmd.get("desc", cmd_name)))
        
        # Sequence groups
        seq_groups = {}
        for seq, cmd_name in cls._sequences.items():
            prefix = seq[0]
            suffix = seq[1:]
            if prefix not in seq_groups:
                seq_groups[prefix] = []
            cmd = cls._commands.get(cmd_name, {})
            seq_groups[prefix].append((suffix, cmd.get("desc", cmd_name)))
        
        # Sort within groups
        for prefix in seq_groups:
            seq_groups[prefix].sort()
        
        return {"single": sorted(single), "sequences": seq_groups}
    
    @classmethod
    def get_command_for_shortcut(cls, event):
        """Get command name for a key event, or None."""
        combo = event_to_combo(event)
        return cls._shortcuts.get(combo)
    
    @classmethod
    def execute_shortcut(cls, event):
        """Execute command bound to shortcut. Returns (result, error) or (None, None) if not bound."""
        name = cls.get_command_for_shortcut(event)
        if name is None:
            return None, None
        return cls.execute_direct(name)
    
    @classmethod
    def execute_direct(cls, name, *args):
        """Execute a command by name with args."""
        if name not in cls._commands:
            return None, f"Unknown command: {name}"
        try:
            result = cls._commands[name]["func"](cls._context, *args)
            return result, None
        except Exception as e:
            return None, f"Error: {e}"
    
    @classmethod
    def execute(cls, command_string):
        """Execute a command string like 'set brush.size 50'."""
        parts = command_string.strip().split()
        if not parts:
            return None, "No command entered"
        
        name = parts[0]
        args = parts[1:]
        return cls.execute_direct(name, *args)
    
    @classmethod
    def get_commands(cls):
        """Return all registered commands."""
        return cls._commands.copy()
    
    @classmethod
    def get_completions(cls, prefix):
        """Get command names that start with prefix."""
        return [name for name in cls._commands if name.startswith(prefix)]


# =============================================================================
# Built-in Commands
# =============================================================================

def cmd_set(ctx, property_path, value):
    """Set a property. Usage: set brush.size 50"""
    parts = property_path.split(".")
    obj = ctx.canvas
    
    # Navigate to the object
    for part in parts[:-1]:
        obj = getattr(obj, part)
    
    attr = parts[-1]
    old_value = getattr(obj, attr)
    
    # Type coercion based on current type
    if isinstance(old_value, float):
        value = float(value)
    elif isinstance(old_value, int):
        value = int(value)
    elif isinstance(old_value, bool):
        value = value.lower() in ("true", "1", "yes")
    
    setattr(obj, attr, value)
    ctx.canvas.update()
    return f"{property_path} = {value}"

def cmd_get(ctx, property_path):
    """Get a property value. Usage: get brush.size"""
    parts = property_path.split(".")
    obj = ctx.canvas
    
    for part in parts:
        obj = getattr(obj, part)
    
    return f"{property_path} = {obj}"

def cmd_clear(ctx):
    """Clear the canvas."""
    ctx.canvas.canvas_pixmap.fill(QtCore.Qt.white)
    ctx.canvas.invalidate_composite()
    ctx.canvas.update()
    return "Canvas cleared"

def cmd_help(ctx, command_name=None):
    """Show help. Usage: help [command]"""
    if command_name:
        if command_name in CommandRegistry._commands:
            cmd = CommandRegistry._commands[command_name]
            shortcuts = ", ".join(cmd["shortcuts"]) if cmd["shortcuts"] else "none"
            return f"{command_name}: {cmd['desc']} (shortcuts: {shortcuts})"
        return f"Unknown command: {command_name}"
    
    # List all commands
    names = sorted(CommandRegistry._commands.keys())
    return "Commands: " + ", ".join(names)

def cmd_quit(ctx):
    """Quit the application."""
    QtWidgets.QApplication.quit()
    return "Goodbye"

def cmd_color(ctx, color_spec):
    """Set brush color. Usage: color red, color #ff0000, color 255,0,0"""
    tool = ctx.canvas.tool_manager.active
    if not hasattr(tool, 'brush'):
        return "Tool has no brush"
    brush = tool.brush
    
    if color_spec.startswith("#"):
        brush.color = QtGui.QColor(color_spec)
    elif "," in color_spec:
        r, g, b = [int(x.strip()) for x in color_spec.split(",")]
        brush.color = QtGui.QColor(r, g, b)
    else:
        # Named color
        brush.color = QtGui.QColor(color_spec)
    
    if not brush.color.isValid():
        return f"Invalid color: {color_spec}"
    
    ctx.canvas.update()
    return f"Color set to {brush.color.name()}"

def cmd_size(ctx, size):
    """Set brush size. Usage: size 50"""
    tool = ctx.canvas.tool_manager.active
    if hasattr(tool, 'brush'):
        tool.brush.size = float(size)
        ctx.canvas.update()
        return f"Size: {size}px"
    return "Tool has no brush"

def cmd_size_increase(ctx):
    """Increase brush size by 10%."""
    tool = ctx.canvas.tool_manager.active
    if hasattr(tool, 'brush'):
        tool.brush.size = min(1000.0, tool.brush.size * 1.1)
        ctx.canvas.update()
        return f"Size: {tool.brush.size:.1f}px"
    return "Tool has no brush"

def cmd_size_decrease(ctx):
    """Decrease brush size by 10%."""
    tool = ctx.canvas.tool_manager.active
    if hasattr(tool, 'brush'):
        tool.brush.size = max(1.0, tool.brush.size * 0.9)
        ctx.canvas.update()
        return f"Size: {tool.brush.size:.1f}px"
    return "Tool has no brush"

def cmd_zoom_fit(ctx):
    """Reset zoom and pan to fit canvas."""
    ctx.canvas.scale = 1.0
    ctx.canvas.offset = QtCore.QPointF(0, 0)
    ctx.canvas.update()
    return "Zoom: fit"

def cmd_opacity(ctx, opacity):
    """Set brush opacity (0-100). Usage: opacity 50"""
    tool = ctx.canvas.tool_manager.active
    if hasattr(tool, 'brush'):
        tool.brush.opacity = float(opacity) / 100.0
        ctx.canvas.update()
        return f"Opacity: {opacity}%"
    return "Tool has no brush"

# opacity presets
def _make_opacity_cmd(percent):
    def cmd(ctx):
        tool = ctx.canvas.tool_manager.active
        if hasattr(tool, 'brush'):
            tool.brush.opacity = percent / 100.0
            ctx.canvas.update()
            return f"Opacity: {percent}%"
        return "Tool has no brush"
    cmd.__doc__ = f"Set brush opacity to {percent}%"
    return cmd

cmd_opacity_10 = _make_opacity_cmd(10)
cmd_opacity_20 = _make_opacity_cmd(20)
cmd_opacity_30 = _make_opacity_cmd(30)
cmd_opacity_40 = _make_opacity_cmd(40)
cmd_opacity_50 = _make_opacity_cmd(50)
cmd_opacity_60 = _make_opacity_cmd(60)
cmd_opacity_70 = _make_opacity_cmd(70)
cmd_opacity_80 = _make_opacity_cmd(80)
cmd_opacity_90 = _make_opacity_cmd(90)
cmd_opacity_100 = _make_opacity_cmd(100)

def cmd_zoom(ctx, level=None):
    """Set zoom level (percentage) or reset. Usage: zoom 200, zoom fit"""
    if level is None or level == "fit":
        ctx.canvas.scale = 1.0
        ctx.canvas.offset = QtCore.QPointF(0, 0)
        ctx.canvas.update()
        return "Zoom: fit"
    
    ctx.canvas.scale = float(level) / 100.0
    ctx.canvas.update()
    return f"Zoom: {level}%"

def cmd_save(ctx, filename=None):
    """Export current frame as PNG."""
    if not filename : 
        # open a file dialog
        filename, _ = QtWidgets.QFileDialog.getSaveFileName(ctx, "Export Canvas", "", "PNG Files (*.png);;All Files (*)")
    if not filename:
        return "Export cancelled"
    if not filename.endswith(".png"):
        filename += ".png"
    ctx.canvas.canvas_pixmap.save(filename)
    return f"Exported to {filename}"

def cmd_project_save(ctx):
    """Save project to .reskia file. Creates new if none loaded."""
    if not hasattr(ctx, 'project') or not ctx.project:
        # No project - prompt to create one
        return cmd_project_new(ctx)
    
    ctx.project.save()
    return f"Saved: {ctx.project.path.name}"

def cmd_project_open(ctx):
    """Open a .reskia project file."""
    from Timeline import Project
    
    filename, _ = QtWidgets.QFileDialog.getOpenFileName(
        ctx, "Open Project", "", 
        "Reskia Projects (*.reskia);;All Files (*)"
    )
    if not filename:
        return "Open cancelled"
    
    from pathlib import Path
    project = Project.load(Path(filename))
    if project:
        ctx.project = project
        ctx.canvas.project = project
        ctx.timeline_panel.set_project(project)
        ctx.canvas.update()
        return f"Opened: {project.name}"
    return "Failed to open project"

def cmd_project_new(ctx):
    """Create a new project."""
    from Timeline import Project
    from pathlib import Path
    
    filename, _ = QtWidgets.QFileDialog.getSaveFileName(
        ctx, "New Project", "", 
        "Reskia Projects (*.reskia);;All Files (*)"
    )
    if not filename:
        return "Cancelled"
    
    path = Path(filename)
    if path.suffix != ".reskia":
        path = path.with_suffix(".reskia")
    
    project = Project.create(path)
    ctx.project = project
    ctx.canvas.project = project
    ctx.timeline_panel.set_project(project)
    ctx.canvas.update()
    return f"Created: {project.name}"

def cmd_undo(ctx):
    """Undo last action."""
    if ctx.canvas.undo_stack:
        ctx.canvas.redo_stack.append(ctx.canvas.canvas_pixmap.copy())
        ctx.canvas.canvas_pixmap = ctx.canvas.undo_stack.pop()
        ctx.canvas.invalidate_composite()
        ctx.canvas.update()
        return "Undone"
    return "Nothing to undo"

def cmd_redo(ctx):
    """Redo last undone action."""
    if ctx.canvas.redo_stack:
        ctx.canvas.undo_stack.append(ctx.canvas.canvas_pixmap.copy())
        ctx.canvas.canvas_pixmap = ctx.canvas.redo_stack.pop()
        ctx.canvas.invalidate_composite()
        ctx.canvas.update()
        return "Redone"
    return "Nothing to redo"


# Register built-in commands
CommandRegistry.register("set", cmd_set, "Set a property value")
CommandRegistry.register("get", cmd_get, "Get a property value")
CommandRegistry.register("clear", cmd_clear, "Clear the canvas", [])
CommandRegistry.register("help", cmd_help, "Show help for commands")
CommandRegistry.register("q", cmd_quit, "Quit application")
CommandRegistry.register("quit", cmd_quit, "Quit application")
CommandRegistry.register("color", cmd_color, "Set brush color")
CommandRegistry.register("size", cmd_size, "Set brush size")
CommandRegistry.register("size.increase", cmd_size_increase, "Increase brush size", ["W"])
CommandRegistry.register("size.decrease", cmd_size_decrease, "Decrease brush size", ["Q"])
CommandRegistry.register("opacity", cmd_opacity, "Set brush opacity (0-100)")
CommandRegistry.register("opacity.10", cmd_opacity_10, "Set opacity 10%", ["o1"])
CommandRegistry.register("opacity.20", cmd_opacity_20, "Set opacity 20%", ["o2"])
CommandRegistry.register("opacity.30", cmd_opacity_30, "Set opacity 30%", ["o3"])
CommandRegistry.register("opacity.40", cmd_opacity_40, "Set opacity 40%", ["o4"])
CommandRegistry.register("opacity.50", cmd_opacity_50, "Set opacity 50%", ["o5"])
CommandRegistry.register("opacity.60", cmd_opacity_60, "Set opacity 60%", ["o6"])
CommandRegistry.register("opacity.70", cmd_opacity_70, "Set opacity 70%", ["o7"])
CommandRegistry.register("opacity.80", cmd_opacity_80, "Set opacity 80%", ["o8"])
CommandRegistry.register("opacity.90", cmd_opacity_90, "Set opacity 90%", ["o9"])
CommandRegistry.register("opacity.100", cmd_opacity_100, "Set opacity 100%", ["o0"])

# Color gray presets: c1=10% gray (light), c0=100% black
def _make_gray_cmd(percent):
    def cmd(ctx):
        tool = ctx.canvas.tool_manager.active
        if hasattr(tool, 'brush'):
            gray = int(255 * (1 - percent / 100.0))  # 0% = white (255), 100% = black (0)
            tool.brush.color = QtGui.QColor(gray, gray, gray)
            ctx.canvas.update()
            return f"Gray: {percent}%"
        return "Tool has no brush"
    cmd.__doc__ = f"Set brush to {percent}% gray"
    return cmd

# c1=10% gray, c2=20%, ..., c9=90%, c0=100% black
for i in range(1, 10):
    CommandRegistry.register_sequence("c", str(i), _make_gray_cmd(i * 10), f"{i*10}% gray")
CommandRegistry.register_sequence("c", "0", _make_gray_cmd(100), "100% black")
CommandRegistry.register("zoom", cmd_zoom, "Set zoom level or fit")
CommandRegistry.register("zoom.fit", cmd_zoom_fit, "Reset zoom and pan", ["F"])
CommandRegistry.register("export", cmd_save, "Export frame as PNG", ["Ctrl+E"])
CommandRegistry.register("project.save", cmd_project_save, "Save project", ["Ctrl+S"])
CommandRegistry.register("project.open", cmd_project_open, "Open project", ["Ctrl+O"])
CommandRegistry.register("project.new", cmd_project_new, "New project", ["Ctrl+N"])
CommandRegistry.register("undo", cmd_undo, "Undo last action", ["Ctrl+Z", "U"])
CommandRegistry.register("redo", cmd_redo, "Redo last undone action", ["Ctrl+Y", "R"])

# Tool commands
def cmd_tool_brush(ctx):
    """Switch to brush tool."""
    ctx.canvas.tool_manager.set_tool("brush")
    return "Brush"

def cmd_tool_eraser(ctx):
    """Switch to eraser tool."""
    ctx.canvas.tool_manager.set_tool("eraser")
    return "Eraser"

def cmd_tool_swap(ctx):
    """Swap to previous tool."""
    ctx.canvas.tool_manager.swap_previous()
    return ctx.canvas.tool_manager.active.name.capitalize()

def cmd_toggle_accumulation(ctx):
    """Toggle brush accumulation mode."""
    tool = ctx.canvas.tool_manager.active
    if hasattr(tool, 'brush'):
        tool.brush.accumulation = not tool.brush.accumulation
        state = "ON" if tool.brush.accumulation else "OFF"
        return f"Accumulation: {state}"
    return "Tool has no brush"

CommandRegistry.register("tool.brush", cmd_tool_brush, "Switch to brush", ["B"])
CommandRegistry.register("tool.eraser", cmd_tool_eraser, "Switch to eraser", ["E"])
CommandRegistry.register("tool.swap", cmd_tool_swap, "Swap previous tool", ["X"])
CommandRegistry.register("brush.accumulation", cmd_toggle_accumulation, "Toggle accumulation", ["A"])

# -------------------------------------------------------------------
# Panel Commands
# -------------------------------------------------------------------

def cmd_toggle_layers(ctx):
    """Toggle timeline panel visibility."""
    ctx.timeline_panel.toggle()
    state = "shown" if ctx.timeline_panel.isVisible() else "hidden"
    return f"Timeline {state}"

CommandRegistry.register("layers.toggle", cmd_toggle_layers, "Toggle timeline panel", ["N"])

# -------------------------------------------------------------------
# Layer Commands
# -------------------------------------------------------------------

def cmd_layer_add(ctx):
    """Add a new layer above current."""
    if not hasattr(ctx, 'project') or not ctx.project or not ctx.project.shot:
        return "No project"
    
    shot = ctx.project.shot
    # Generate unique name
    base = "layer"
    n = len(shot.layers) + 1
    name = f"{base}_{n}"
    while shot.get_layer(name):
        n += 1
        name = f"{base}_{n}"
    
    # Insert above active layer
    idx = shot.active_layer_idx + 1
    layer = shot.add_layer(name, index=idx)
    
    # Create initial keyframe at frame 1
    layer.insert_keyframe(1, ctx.project.canvas_size, duplicate=False)
    
    # Select the new layer
    shot.active_layer_idx = idx
    
    ctx.canvas.invalidate_composite()
    ctx.canvas.update()
    ctx.timeline_panel.update_display()
    return f"Added: {name}"

def cmd_layer_delete(ctx):
    """Delete current layer."""
    if not hasattr(ctx, 'project') or not ctx.project or not ctx.project.shot:
        return "No project"
    
    shot = ctx.project.shot
    if len(shot.layers) <= 1:
        return "Can't delete last layer"
    
    idx = shot.active_layer_idx
    name = shot.layers[idx].name
    shot.layers.pop(idx)
    
    # Adjust active index
    if shot.active_layer_idx >= len(shot.layers):
        shot.active_layer_idx = len(shot.layers) - 1
    
    ctx.canvas.invalidate_composite()
    ctx.canvas.update()
    ctx.timeline_panel.update_display()
    return f"Deleted: {name}"

def cmd_layer_up(ctx):
    """Move current layer up (toward front)."""
    if not hasattr(ctx, 'project') or not ctx.project or not ctx.project.shot:
        return "No project"
    
    shot = ctx.project.shot
    idx = shot.active_layer_idx
    if idx >= len(shot.layers) - 1:
        return "Already at top"
    
    shot.layers[idx], shot.layers[idx + 1] = shot.layers[idx + 1], shot.layers[idx]
    shot.active_layer_idx = idx + 1
    
    ctx.canvas.invalidate_composite()
    ctx.canvas.update()
    ctx.timeline_panel.update_display()
    return f"Layer moved up"

def cmd_layer_down(ctx):
    """Move current layer down (toward back)."""
    if not hasattr(ctx, 'project') or not ctx.project or not ctx.project.shot:
        return "No project"
    
    shot = ctx.project.shot
    idx = shot.active_layer_idx
    if idx <= 0:
        return "Already at bottom"
    
    shot.layers[idx], shot.layers[idx - 1] = shot.layers[idx - 1], shot.layers[idx]
    shot.active_layer_idx = idx - 1
    
    ctx.canvas.invalidate_composite()
    ctx.canvas.update()
    ctx.timeline_panel.update_display()
    return f"Layer moved down"

def cmd_layer_rename(ctx, new_name=None):
    """Rename current layer."""
    if not hasattr(ctx, 'project') or not ctx.project or not ctx.project.shot:
        return "No project"
    
    layer = ctx.project.shot.active_layer
    if not layer:
        return "No active layer"
    
    if not new_name:
        new_name, ok = QtWidgets.QInputDialog.getText(
            ctx, "Rename Layer", "New name:", text=layer.name
        )
        if not ok or not new_name:
            return "Cancelled"
    
    old_name = layer.name
    layer.name = new_name
    ctx.timeline_panel.update_display()
    return f"Renamed: {old_name} -> {new_name}"

CommandRegistry.register("layer.add", cmd_layer_add, "Add new layer", ["Ctrl+Shift+N"])
CommandRegistry.register("layer.delete", cmd_layer_delete, "Delete layer", [])
CommandRegistry.register("layer.up", cmd_layer_up, "Move layer up", ["Ctrl+]"])
CommandRegistry.register("layer.down", cmd_layer_down, "Move layer down", ["Ctrl+["])
CommandRegistry.register("layer.rename", cmd_layer_rename, "Rename layer", [])

def cmd_layer_visibility(ctx):
    """Toggle current layer visibility."""
    if not hasattr(ctx, 'project') or not ctx.project or not ctx.project.shot:
        return "No project"
    
    layer = ctx.project.shot.active_layer
    if not layer:
        return "No active layer"
    
    layer.visible = not layer.visible
    ctx.canvas.invalidate_composite()
    ctx.canvas.update()
    ctx.timeline_panel.update_display()
    state = "visible" if layer.visible else "hidden"
    return f"{layer.name}: {state}"

def cmd_layer_lock(ctx):
    """Toggle current layer lock."""
    if not hasattr(ctx, 'project') or not ctx.project or not ctx.project.shot:
        return "No project"
    
    layer = ctx.project.shot.active_layer
    if not layer:
        return "No active layer"
    
    layer.locked = not layer.locked
    ctx.timeline_panel.update_display()
    state = "locked" if layer.locked else "unlocked"
    return f"{layer.name}: {state}"

CommandRegistry.register("layer.visibility", cmd_layer_visibility, "Toggle layer visibility", [])
CommandRegistry.register("layer.lock", cmd_layer_lock, "Toggle layer lock", [])

# -------------------------------------------------------------------
# Frame Navigation
# -------------------------------------------------------------------

def cmd_frame_prev(ctx):
    """Go to previous frame (step by frame)."""
    if hasattr(ctx, 'project') and ctx.project and ctx.project.shot:
        frame = ctx.project.prev_frame()
        ctx.canvas.invalidate_composite()
        ctx.canvas.update()
        ctx.timeline_panel.update_display()
        return f"Frame {frame}"
    return "No project"

def cmd_frame_next(ctx):
    """Go to next frame (step by frame)."""
    if hasattr(ctx, 'project') and ctx.project and ctx.project.shot:
        frame = ctx.project.next_frame()
        ctx.canvas.invalidate_composite()
        ctx.canvas.update()
        ctx.timeline_panel.update_display()
        return f"Frame {frame}"
    return "No project"

def cmd_keyframe_prev(ctx):
    """Go to previous keyframe in active layer."""
    if hasattr(ctx, 'project') and ctx.project and ctx.project.shot:
        frame = ctx.project.prev_keyframe()
        ctx.canvas.invalidate_composite()
        ctx.canvas.update()
        ctx.timeline_panel.update_display()
        return f"Keyframe at {frame}"
    return "No project"

def cmd_keyframe_next(ctx):
    """Go to next keyframe in active layer."""
    if hasattr(ctx, 'project') and ctx.project and ctx.project.shot:
        frame = ctx.project.next_keyframe()
        ctx.canvas.invalidate_composite()
        ctx.canvas.update()
        ctx.timeline_panel.update_display()
        return f"Keyframe at {frame}"
    return "No project"

def cmd_onion_toggle(ctx):
    """Toggle onion skin."""
    if hasattr(ctx, 'project') and ctx.project:
        ctx.project.onion_enabled = not ctx.project.onion_enabled
        ctx.canvas.invalidate_composite()  # Onion affects cache
        ctx.canvas.update()
        state = "ON" if ctx.project.onion_enabled else "OFF"
        return f"Onion: {state}"
    return "No project"

# ,/. = step through keyframes (like Maya timeline)
# Alt+,/Alt+. = step through every frame
CommandRegistry.register("keyframe.prev", cmd_keyframe_prev, "Previous keyframe", [","])
CommandRegistry.register("keyframe.next", cmd_keyframe_next, "Next keyframe", ["."])
CommandRegistry.register("frame.prev", cmd_frame_prev, "Previous frame", ["Alt+,"])
CommandRegistry.register("frame.next", cmd_frame_next, "Next frame", ["Alt+."])
CommandRegistry.register("onion.toggle", cmd_onion_toggle, "Toggle onion skin", ["P"])

# -------------------------------------------------------------------
# Keyframe Creation (Flash-style F6/F7)
# -------------------------------------------------------------------

def cmd_insert_keyframe(ctx):
    """Insert keyframe at current frame, copying content from previous (F6 style)."""
    if not hasattr(ctx, 'project') or not ctx.project or not ctx.project.shot:
        return "No project loaded"
    
    shot = ctx.project.shot
    layer = shot.active_layer
    if not layer:
        return "No active layer"
    
    frame = shot.current_frame
    
    # Check if already a keyframe here
    if layer.is_keyframe_at(frame):
        return f"Already a keyframe at {frame}"
    
    # Insert duplicating from previous
    kf = layer.insert_keyframe(frame, ctx.project.canvas_size, duplicate=True)
    ctx.canvas.update()
    ctx.timeline_panel.update_display()
    return f"Keyframe inserted at {frame}"

def cmd_insert_blank_keyframe(ctx):
    """Insert blank keyframe at current frame (F7 style)."""
    if not hasattr(ctx, 'project') or not ctx.project or not ctx.project.shot:
        return "No project loaded"
    
    shot = ctx.project.shot
    layer = shot.active_layer
    if not layer:
        return "No active layer"
    
    frame = shot.current_frame
    
    # Check if already a keyframe here
    existing = layer.get_keyframe_exact(frame)
    if existing:
        # Clear the existing keyframe content
        existing._pixmap = QtGui.QPixmap(ctx.project.canvas_size)
        existing._pixmap.fill(QtCore.Qt.transparent)
        existing._dirty = True
        ctx.canvas.update()
        ctx.timeline_panel.update_display()
        return f"Cleared keyframe at {frame}"
    
    # Insert blank
    kf = layer.insert_keyframe(frame, ctx.project.canvas_size, duplicate=False)
    ctx.canvas.update()
    ctx.timeline_panel.update_display()
    return f"Blank keyframe at {frame}"

def cmd_delete_keyframe(ctx):
    """Delete keyframe at current frame."""
    if not hasattr(ctx, 'project') or not ctx.project or not ctx.project.shot:
        return "No project loaded"
    
    shot = ctx.project.shot
    layer = shot.active_layer
    if not layer:
        return "No active layer"
    
    frame = shot.current_frame
    
    if layer.delete_keyframe(frame):
        ctx.canvas.update()
        ctx.timeline_panel.update_display()
        return f"Deleted keyframe at {frame}"
    return f"No keyframe at {frame}"

def cmd_extend_duration(ctx):
    """Add 12 frames to shot duration."""
    if not hasattr(ctx, 'project') or not ctx.project or not ctx.project.shot:
        return "No project loaded"
    
    ctx.project.shot.duration += 12
    ctx.timeline_panel.update_display()
    return f"Duration: {ctx.project.shot.duration}"

# F6 = insert keyframe (duplicate), F7 = insert blank keyframe
CommandRegistry.register("keyframe.insert", cmd_insert_keyframe, "Insert keyframe (F6)", ["F6"])
CommandRegistry.register("keyframe.blank", cmd_insert_blank_keyframe, "Blank keyframe (F7)", ["F7"])
CommandRegistry.register("keyframe.delete", cmd_delete_keyframe, "Delete keyframe", ["Shift+F7"])
CommandRegistry.register("duration.extend", cmd_extend_duration, "Extend duration +12", [])

# -------------------------------------------------------------------
# Keyframe Clipboard & Frame Operations
# -------------------------------------------------------------------

# Module-level clipboard for keyframe copy/paste
_keyframe_clipboard = None  # Will hold a QPixmap

def cmd_yank_keyframe(ctx):
    """Copy (yank) keyframe at current frame."""
    global _keyframe_clipboard
    if not hasattr(ctx, 'project') or not ctx.project or not ctx.project.shot:
        return "No project"
    
    layer = ctx.project.shot.active_layer
    if not layer:
        return "No active layer"
    
    pixmap = layer.copy_keyframe(ctx.project.shot.current_frame)
    if pixmap:
        _keyframe_clipboard = pixmap
        return "Keyframe yanked"
    return "No keyframe to yank"

def cmd_paste_keyframe(ctx):
    """Paste keyframe at current frame."""
    global _keyframe_clipboard
    if not hasattr(ctx, 'project') or not ctx.project or not ctx.project.shot:
        return "No project"
    
    if _keyframe_clipboard is None:
        return "Clipboard empty"
    
    layer = ctx.project.shot.active_layer
    if not layer:
        return "No active layer"
    
    layer.paste_keyframe(
        ctx.project.shot.current_frame, 
        _keyframe_clipboard, 
        ctx.project.canvas_size
    )
    ctx.canvas.update()
    ctx.timeline_panel.update_display()
    return f"Pasted at frame {ctx.project.shot.current_frame}"

def cmd_insert_frame(ctx):
    """Insert blank frame after current position, extending hold."""
    if not hasattr(ctx, 'project') or not ctx.project or not ctx.project.shot:
        return "No project"
    
    shot = ctx.project.shot
    insert_at = shot.current_frame + 1
    shot.insert_frame_at(insert_at)
    ctx.canvas.update()
    ctx.timeline_panel.update_display()
    return f"+1 frame after {shot.current_frame}, duration: {shot.duration}"

def cmd_remove_frame(ctx):
    """Remove frame after current position, shrinking hold."""
    if not hasattr(ctx, 'project') or not ctx.project or not ctx.project.shot:
        return "No project"
    
    shot = ctx.project.shot
    remove_at = shot.current_frame + 1
    if remove_at > shot.duration:
        return "No frame to remove"
    deleted = shot.remove_frame_at(remove_at)
    ctx.canvas.update()
    ctx.timeline_panel.update_display()
    msg = f"-1 frame after {shot.current_frame}, duration: {shot.duration}"
    if deleted:
        msg += f" (keyframe deleted)"
    return msg

def cmd_clear_keyframe(ctx):
    """Clear keyframe content (make transparent) without deleting it."""
    if not hasattr(ctx, 'project') or not ctx.project or not ctx.project.shot:
        return "No project"
    
    layer = ctx.project.shot.active_layer
    if not layer:
        return "No active layer"
    
    frame = ctx.project.shot.current_frame
    kf = layer.get_keyframe_exact(frame)
    if kf:
        kf._pixmap = QtGui.QPixmap(ctx.project.canvas_size)
        kf._pixmap.fill(QtCore.Qt.transparent)
        kf._dirty = True
        ctx.canvas.update()
        ctx.timeline_panel.update_display()
        return f"Cleared keyframe at {frame}"
    return f"No keyframe at {frame}"

# k-sequences for keyframe operations
CommandRegistry.register_sequence("k", "i", cmd_insert_keyframe, "insert keyframe")
CommandRegistry.register_sequence("k", "k", cmd_insert_blank_keyframe, "blank keyframe")
CommandRegistry.register_sequence("k", "x", cmd_delete_keyframe, "delete keyframe")
CommandRegistry.register_sequence("k", "c", cmd_clear_keyframe, "clear keyframe")
CommandRegistry.register_sequence("k", "y", cmd_yank_keyframe, "yank keyframe")
CommandRegistry.register_sequence("k", "p", cmd_paste_keyframe, "paste keyframe")

# Frame operations (+/- to add/remove frames)
CommandRegistry.register("frame.insert", cmd_insert_frame, "Insert frame", ["+"])
CommandRegistry.register("frame.remove", cmd_remove_frame, "Remove frame", ["-"])

# l-sequences for layer operations (vim-style j=down, k=up)
CommandRegistry.register_sequence("l", "n", cmd_layer_add, "new layer")
CommandRegistry.register_sequence("l", "x", cmd_layer_delete, "delete layer")
CommandRegistry.register_sequence("l", "r", cmd_layer_rename, "rename layer")
CommandRegistry.register_sequence("l", "k", cmd_layer_up, "layer up")
CommandRegistry.register_sequence("l", "j", cmd_layer_down, "layer down")
CommandRegistry.register_sequence("l", "v", cmd_layer_visibility, "toggle visibility")
CommandRegistry.register_sequence("l", "l", cmd_layer_lock, "toggle lock")

# -------------------------------------------------------------------
# Brush Mode
# -------------------------------------------------------------------

def cmd_mode_normal(ctx):
    """Set brush mode to Normal."""
    brush = ctx.canvas.tool_manager.active.brush
    brush.mode = "normal"
    return "Mode: Normal"

def cmd_mode_behind(ctx):
    """Set brush mode to Behind."""
    brush = ctx.canvas.tool_manager.active.brush
    brush.mode = "behind"
    return "Mode: Behind"

def cmd_mode_multiply(ctx):
    """Set brush mode to Multiply."""
    brush = ctx.canvas.tool_manager.active.brush
    brush.mode = "multiply"
    return "Mode: Multiply"

def cmd_mode_overlay(ctx):
    """Set brush mode to Overlay."""
    brush = ctx.canvas.tool_manager.active.brush
    brush.mode = "overlay"
    return "Mode: Overlay"

def cmd_mode_cycle(ctx):
    """Cycle brush mode."""
    brush = ctx.canvas.tool_manager.active.brush
    mode = brush.cycle_mode()
    return f"Mode: {mode.capitalize()}"

# Mode sequences: m1=normal, m2=behind, m3=multiply, m4=overlay
CommandRegistry.register_sequence("m", "1", cmd_mode_normal, "normal")
CommandRegistry.register_sequence("m", "2", cmd_mode_behind, "behind")
CommandRegistry.register_sequence("m", "3", cmd_mode_multiply, "multiply")
CommandRegistry.register_sequence("m", "4", cmd_mode_overlay, "overlay")
CommandRegistry.register("mode.cycle", cmd_mode_cycle, "Cycle brush mode", ["M"])

# -------------------------------------------------------------------
# Project Commands
# -------------------------------------------------------------------

def cmd_export_shot(ctx):
    """Export current shot to flattened PNGs."""
    if hasattr(ctx, 'project') and ctx.project:
        count = ctx.project.export_shot()
        return f"Exported {count} frames"
    return "No project"

CommandRegistry.register("export.shot", cmd_export_shot, "Export shot", [])

def cmd_shortcuts(ctx):
    """Show all shortcuts in a popup."""
    if hasattr(ctx, 'which_key'):
        ctx.which_key.show_all_shortcuts()
    return ""

CommandRegistry.register("shortcuts", cmd_shortcuts, "Show all shortcuts", ["?"])
