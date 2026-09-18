"""
Timeline - Keyframe-based animation data model with ZIP storage.

Storage format (.reskia file = ZIP archive):
    myproject.reskia
    ├── project.json          # Project metadata + timeline structure
    └── keyframes/
        ├── layer_001_k001.bin   # zlib-compressed RGBA bytes
        ├── layer_001_k002.bin
        └── ...

Timeline model:
    Project
    └── Shot (one active shot at a time for now)
        └── Layer (bg, char_*, fg)
            └── Keyframe (starts at frame N, holds until next keyframe)
"""

from __future__ import annotations
import json
import zlib
import zipfile
from pathlib import Path
from dataclasses import dataclass, field
from typing import Optional
from io import BytesIO

import PySide6.QtCore as QtCore
import PySide6.QtGui as QtGui


# =============================================================================
# Keyframe
# =============================================================================

@dataclass
class Keyframe:
    """
    A keyframe holding image data starting at a specific frame.
    
    The keyframe "holds" until the next keyframe in the layer.
    """
    frame: int  # Frame number where this keyframe starts (1-indexed)
    _pixmap: Optional[QtGui.QPixmap] = None
    _dirty: bool = False
    
    # Unique ID for storage (set by layer when adding)
    _id: str = ""
    
    @property
    def pixmap(self) -> Optional[QtGui.QPixmap]:
        return self._pixmap
    
    @pixmap.setter
    def pixmap(self, value: QtGui.QPixmap):
        self._pixmap = value
        self._dirty = True
    
    def get_or_create_pixmap(self, size: QtCore.QSize) -> QtGui.QPixmap:
        """Get pixmap, creating or resizing if needed."""
        if self._pixmap is None or self._pixmap.size() != size:
            if self._pixmap is None:
                self._pixmap = QtGui.QPixmap(size)
                self._pixmap.fill(QtCore.Qt.transparent)
            else:
                # Resize existing pixmap (shouldn't happen normally, but handle it)
                old = self._pixmap
                self._pixmap = QtGui.QPixmap(size)
                self._pixmap.fill(QtCore.Qt.transparent)
                painter = QtGui.QPainter(self._pixmap)
                painter.drawPixmap(0, 0, old)
                painter.end()
                self._dirty = True
        return self._pixmap
    
    def to_bytes(self) -> bytes:
        """Compress pixmap to bytes for storage."""
        if self._pixmap is None:
            return b''
        
        image = self._pixmap.toImage()
        # Convert to ARGB32 for consistent format
        image = image.convertToFormat(QtGui.QImage.Format_ARGB32)
        
        # Get raw bytes
        ptr = image.bits()
        raw = bytes(ptr)
        
        # Compress
        return zlib.compress(raw, level=6)
    
    @classmethod
    def from_bytes(cls, data: bytes, width: int, height: int, frame: int, key_id: str) -> Keyframe:
        """Create keyframe from compressed bytes."""
        kf = cls(frame=frame, _id=key_id)
        
        if data:
            raw = zlib.decompress(data)
            image = QtGui.QImage(raw, width, height, QtGui.QImage.Format_ARGB32)
            kf._pixmap = QtGui.QPixmap.fromImage(image.copy())  # copy to detach from raw buffer
        
        kf._dirty = False
        return kf


# =============================================================================
# Layer
# =============================================================================

@dataclass
class Layer:
    """
    A layer containing keyframes.
    
    Keyframes are sorted by frame number. A keyframe "holds" from its
    frame until the frame before the next keyframe.
    """
    name: str  # "bg", "char_main", "fg", etc.
    keyframes: list[Keyframe] = field(default_factory=list)
    visible: bool = True
    locked: bool = False
    
    # For generating unique keyframe IDs
    _next_key_id: int = 1
    
    def __post_init__(self):
        if not self.keyframes:
            self.keyframes = []
    
    def _generate_key_id(self) -> str:
        """Generate unique keyframe ID for this layer."""
        key_id = f"k{self._next_key_id:04d}"
        self._next_key_id += 1
        return key_id
    
    def get_keyframe_at(self, frame: int) -> Optional[Keyframe]:
        """
        Get the keyframe that is active at the given frame.
        
        Returns the keyframe with the highest frame number <= given frame.
        Returns None if frame is before all keyframes.
        """
        result = None
        for kf in self.keyframes:
            if kf.frame <= frame:
                result = kf
            else:
                break  # keyframes are sorted, so we can stop
        return result
    
    def get_keyframe_exact(self, frame: int) -> Optional[Keyframe]:
        """Get keyframe that starts exactly at this frame, or None."""
        for kf in self.keyframes:
            if kf.frame == frame:
                return kf
            if kf.frame > frame:
                break
        return None
    
    def is_keyframe_at(self, frame: int) -> bool:
        """Check if there's a keyframe starting exactly at this frame."""
        return self.get_keyframe_exact(frame) is not None
    
    def insert_keyframe(self, frame: int, size: QtCore.QSize, 
                        duplicate: bool = True) -> Keyframe:
        """
        Insert a keyframe at the given frame.
        
        Args:
            frame: Frame number to insert at
            size: Canvas size for creating pixmap
            duplicate: If True, copy content from previous keyframe (F6 style)
                      If False, create blank keyframe (F7 style)
        
        Returns the new or existing keyframe.
        """
        # Check if keyframe already exists
        existing = self.get_keyframe_exact(frame)
        if existing:
            return existing
        
        # Create new keyframe
        kf = Keyframe(frame=frame, _id=self._generate_key_id())
        
        if duplicate:
            # Copy content from the keyframe that was active at this frame
            prev = self.get_keyframe_at(frame)
            if prev and prev._pixmap:
                kf._pixmap = prev._pixmap.copy()
            else:
                kf._pixmap = QtGui.QPixmap(size)
                kf._pixmap.fill(QtCore.Qt.transparent)
        else:
            # Blank keyframe
            kf._pixmap = QtGui.QPixmap(size)
            kf._pixmap.fill(QtCore.Qt.transparent)
        
        kf._dirty = True
        
        # Insert in sorted order
        self.keyframes.append(kf)
        self.keyframes.sort(key=lambda k: k.frame)
        
        return kf
    
    def delete_keyframe(self, frame: int) -> bool:
        """Delete keyframe at exact frame. Returns True if deleted."""
        for i, kf in enumerate(self.keyframes):
            if kf.frame == frame:
                self.keyframes.pop(i)
                return True
            if kf.frame > frame:
                break
        return False
    
    def move_keyframe(self, from_frame: int, to_frame: int) -> bool:
        """Move keyframe from one frame to another. Returns True if moved."""
        if from_frame == to_frame:
            return False
        
        # Get keyframe at source
        source_kf = self.get_keyframe_exact(from_frame)
        if not source_kf:
            return False
        
        # Check if target has a keyframe - swap them
        target_kf = self.get_keyframe_exact(to_frame)
        if target_kf:
            # Swap frames
            source_kf.frame = to_frame
            target_kf.frame = from_frame
        else:
            # Just move
            source_kf.frame = to_frame
        
        source_kf._dirty = True
        if target_kf:
            target_kf._dirty = True
        
        # Re-sort keyframes
        self.keyframes.sort(key=lambda k: k.frame)
        return True
    
    def insert_frame_at(self, frame: int) -> None:
        """Insert a frame at position, shifting all keyframes at/after by +1."""
        for kf in self.keyframes:
            if kf.frame >= frame:
                kf.frame += 1
                kf._dirty = True
    
    def remove_frame_at(self, frame: int) -> bool:
        """Remove frame at position. Deletes keyframe if present, shifts others -1.
        
        Returns True if a keyframe was deleted.
        """
        deleted = self.delete_keyframe(frame)
        
        # Shift all keyframes after this frame
        for kf in self.keyframes:
            if kf.frame > frame:
                kf.frame -= 1
                kf._dirty = True
        
        return deleted
    
    def copy_keyframe(self, frame: int) -> Optional[QtGui.QPixmap]:
        """Copy keyframe pixmap at frame. Returns pixmap copy or None."""
        kf = self.get_keyframe_at(frame)
        if kf and kf._pixmap:
            return kf._pixmap.copy()
        return None
    
    def paste_keyframe(self, frame: int, pixmap: QtGui.QPixmap, size: QtCore.QSize) -> Keyframe:
        """Paste pixmap as keyframe at frame. Creates or overwrites keyframe."""
        kf = self.get_keyframe_exact(frame)
        if not kf:
            kf = Keyframe(frame=frame, _id=self._generate_key_id())
            self.keyframes.append(kf)
            self.keyframes.sort(key=lambda k: k.frame)
        
        kf._pixmap = pixmap.copy()
        kf._dirty = True
        return kf
    
    def get_next_keyframe(self, frame: int) -> Optional[Keyframe]:
        """Get the keyframe after the given frame."""
        for kf in self.keyframes:
            if kf.frame > frame:
                return kf
        return None
    
    def get_prev_keyframe(self, frame: int) -> Optional[Keyframe]:
        """Get the keyframe at or before the given frame, then the one before that."""
        prev = None
        for kf in self.keyframes:
            if kf.frame >= frame:
                return prev
            prev = kf
        return prev
    
    def get_keyframe_range(self, keyframe: Keyframe) -> tuple[int, int]:
        """
        Get the frame range [start, end] that a keyframe covers.
        end is inclusive.
        """
        start = keyframe.frame
        next_kf = self.get_next_keyframe(keyframe.frame)
        if next_kf:
            end = next_kf.frame - 1
        else:
            end = -1  # Extends to end of shot
        return (start, end)


# =============================================================================
# Shot
# =============================================================================

@dataclass 
class Shot:
    """
    A shot containing layers with keyframes.
    """
    name: str
    layers: list[Layer] = field(default_factory=list)
    duration: int = 24  # Total frames in shot
    
    # Current state
    current_frame: int = 1  # 1-indexed
    active_layer_idx: int = 0
    
    def __post_init__(self):
        if not self.layers:
            self.layers = []
    
    @property
    def active_layer(self) -> Optional[Layer]:
        if 0 <= self.active_layer_idx < len(self.layers):
            return self.layers[self.active_layer_idx]
        return None
    
    def get_layer(self, name: str) -> Optional[Layer]:
        """Get layer by name."""
        for layer in self.layers:
            if layer.name == name:
                return layer
        return None
    
    def add_layer(self, name: str, index: int = -1) -> Layer:
        """Add a new layer at index (-1 = top)."""
        layer = Layer(name=name)
        if index < 0:
            self.layers.append(layer)
        else:
            self.layers.insert(index, layer)
        return layer
    
    def create_default_layers(self, characters: list[str]):
        """Create standard layer structure: bg, chars, fg."""
        self.layers = []
        self.add_layer("bg")
        for char in characters:
            self.add_layer(f"char_{char}")
        self.add_layer("fg")
        self.active_layer_idx = 1 if characters else 0  # Default to first char layer
    
    def get_composite_at(self, frame: int, size: QtCore.QSize) -> QtGui.QPixmap:
        """Render all visible layers at given frame to a single pixmap."""
        result = QtGui.QPixmap(size)
        result.fill(QtCore.Qt.transparent)
        
        painter = QtGui.QPainter(result)
        
        for layer in self.layers:
            if not layer.visible:
                continue
            kf = layer.get_keyframe_at(frame)
            if kf and kf._pixmap:
                painter.drawPixmap(0, 0, kf._pixmap)
        
        painter.end()
        return result
    
    def goto_frame(self, frame: int) -> int:
        """Navigate to frame, clamping to valid range. Returns actual frame."""
        self.current_frame = max(1, min(frame, self.duration))
        return self.current_frame
    
    def next_frame(self) -> int:
        """Go to next frame."""
        return self.goto_frame(self.current_frame + 1)
    
    def prev_frame(self) -> int:
        """Go to previous frame."""
        return self.goto_frame(self.current_frame - 1)
    
    def next_keyframe(self) -> int:
        """Go to next keyframe in active layer."""
        layer = self.active_layer
        if not layer:
            return self.current_frame
        
        next_kf = layer.get_next_keyframe(self.current_frame)
        if next_kf:
            return self.goto_frame(next_kf.frame)
        return self.current_frame
    
    def prev_keyframe(self) -> int:
        """Go to previous keyframe in active layer."""
        layer = self.active_layer
        if not layer:
            return self.current_frame
        
        # Get keyframe at current position
        current_kf = layer.get_keyframe_at(self.current_frame)
        if current_kf and current_kf.frame == self.current_frame:
            # We're on a keyframe, get the one before it
            prev_kf = layer.get_prev_keyframe(self.current_frame)
            if prev_kf:
                return self.goto_frame(prev_kf.frame)
        elif current_kf:
            # We're in a hold, go to the keyframe we're holding
            return self.goto_frame(current_kf.frame)
        
        return self.current_frame
    
    def insert_frame_at(self, frame: int) -> None:
        """Insert a frame at position across all layers, shifting keyframes forward."""
        for layer in self.layers:
            layer.insert_frame_at(frame)
        self.duration += 1
    
    def remove_frame_at(self, frame: int) -> int:
        """Remove frame at position across all layers. Returns count of deleted keyframes."""
        if self.duration <= 1:
            return 0  # Can't remove from single-frame shot
        
        deleted = 0
        for layer in self.layers:
            if layer.remove_frame_at(frame):
                deleted += 1
        
        self.duration -= 1
        
        # Adjust current frame if needed
        if self.current_frame > self.duration:
            self.current_frame = self.duration
        
        return deleted


# =============================================================================
# Project
# =============================================================================

@dataclass
class Project:
    """
    Project with ZIP-based storage.
    
    Single .reskia file containing all data.
    """
    name: str
    path: Path  # Path to .reskia file
    canvas_width: int = 1920
    canvas_height: int = 1080
    characters: list[str] = field(default_factory=list)
    
    # For now, single shot (can extend to sequences later)
    shot: Optional[Shot] = None
    
    # Onion skin settings
    onion_enabled: bool = False
    onion_before: int = 2
    onion_after: int = 1
    onion_opacity_before: float = 0.3
    onion_opacity_after: float = 0.2
    
    def __post_init__(self):
        if not self.characters:
            self.characters = ["main"]
    
    @property
    def canvas_size(self) -> QtCore.QSize:
        return QtCore.QSize(self.canvas_width, self.canvas_height)
    
    @property
    def current_frame(self) -> int:
        return self.shot.current_frame if self.shot else 1
    
    @property
    def active_layer(self) -> Optional[Layer]:
        return self.shot.active_layer if self.shot else None
    
    def get_current_keyframe(self) -> Optional[Keyframe]:
        """Get the keyframe at current frame for active layer."""
        if not self.shot or not self.shot.active_layer:
            return None
        return self.shot.active_layer.get_keyframe_at(self.shot.current_frame)
    
    def get_or_create_keyframe(self) -> Optional[Keyframe]:
        """Get keyframe at current frame, creating if needed."""
        if not self.shot or not self.shot.active_layer:
            return None
        
        layer = self.shot.active_layer
        frame = self.shot.current_frame
        
        # If there's already a keyframe at this exact frame, return it
        kf = layer.get_keyframe_exact(frame)
        if kf:
            return kf
        
        # Otherwise create one (duplicate style)
        return layer.insert_keyframe(frame, self.canvas_size, duplicate=True)
    
    # -------------------------------------------------------------------------
    # Navigation
    # -------------------------------------------------------------------------
    
    def goto_frame(self, frame: int) -> int:
        if self.shot:
            return self.shot.goto_frame(frame)
        return 1
    
    def next_frame(self) -> int:
        if self.shot:
            return self.shot.next_frame()
        return 1
    
    def prev_frame(self) -> int:
        if self.shot:
            return self.shot.prev_frame()
        return 1
    
    def next_keyframe(self) -> int:
        if self.shot:
            return self.shot.next_keyframe()
        return 1
    
    def prev_keyframe(self) -> int:
        if self.shot:
            return self.shot.prev_keyframe()
        return 1
    
    # -------------------------------------------------------------------------
    # Onion Skin
    # -------------------------------------------------------------------------
    
    def get_onion_keyframes(self) -> list[tuple[Keyframe, float, str]]:
        """
        Get keyframes for onion skin rendering.
        
        Returns: List of (keyframe, opacity, tint) tuples
            tint: "before" or "after"
        """
        if not self.onion_enabled or not self.shot:
            return []
        
        layer = self.shot.active_layer
        if not layer:
            return []
        
        result = []
        frame = self.shot.current_frame
        
        # Get keyframes before current
        check_frame = frame
        for i in range(self.onion_before):
            prev = layer.get_prev_keyframe(check_frame)
            if prev is None:
                # Check if we're after the first keyframe
                kf_at = layer.get_keyframe_at(check_frame - 1)
                if kf_at and kf_at.frame < check_frame:
                    prev = kf_at
                    check_frame = prev.frame
                else:
                    break
            else:
                check_frame = prev.frame
            
            opacity = self.onion_opacity_before * (1 - i / self.onion_before)
            result.insert(0, (prev, opacity, "before"))
        
        # Get keyframes after current
        check_frame = frame
        for i in range(self.onion_after):
            next_kf = layer.get_next_keyframe(check_frame)
            if next_kf is None:
                break
            check_frame = next_kf.frame
            opacity = self.onion_opacity_after * (1 - i / self.onion_after)
            result.append((next_kf, opacity, "after"))
        
        return result
    
    # -------------------------------------------------------------------------
    # Save / Load
    # -------------------------------------------------------------------------
    
    def save(self) -> bool:
        """Save project to .reskia ZIP file."""
        try:
            with zipfile.ZipFile(self.path, 'w', zipfile.ZIP_DEFLATED) as zf:
                # Build project metadata
                project_data = {
                    "name": self.name,
                    "canvas_width": self.canvas_width,
                    "canvas_height": self.canvas_height,
                    "characters": self.characters,
                    "onion_enabled": self.onion_enabled,
                    "onion_before": self.onion_before,
                    "onion_after": self.onion_after,
                    "onion_opacity_before": self.onion_opacity_before,
                    "onion_opacity_after": self.onion_opacity_after,
                }
                
                if self.shot:
                    # Build shot data
                    shot_data = {
                        "name": self.shot.name,
                        "duration": self.shot.duration,
                        "current_frame": self.shot.current_frame,
                        "active_layer_idx": self.shot.active_layer_idx,
                        "layers": []
                    }
                    
                    for layer in self.shot.layers:
                        layer_data = {
                            "name": layer.name,
                            "visible": layer.visible,
                            "locked": layer.locked,
                            "_next_key_id": layer._next_key_id,
                            "keyframes": []
                        }
                        
                        for kf in layer.keyframes:
                            kf_data = {
                                "frame": kf.frame,
                                "id": kf._id
                            }
                            layer_data["keyframes"].append(kf_data)
                            
                            # Save keyframe pixmap data
                            if kf._pixmap is not None:
                                data = kf.to_bytes()
                                key_path = f"keyframes/{layer.name}_{kf._id}.bin"
                                zf.writestr(key_path, data)
                        
                        shot_data["layers"].append(layer_data)
                    
                    project_data["shot"] = shot_data
                
                # Write project.json
                zf.writestr("project.json", json.dumps(project_data, indent=2))
            
            return True
        except Exception as e:
            print(f"Error saving project: {e}")
            return False
    
    @classmethod
    def load(cls, path: Path) -> Optional[Project]:
        """Load project from .reskia ZIP file."""
        if not path.exists():
            return None
        
        try:
            with zipfile.ZipFile(path, 'r') as zf:
                # Read project.json
                project_json = zf.read("project.json")
                data = json.loads(project_json)
                
                project = cls(
                    name=data.get("name", path.stem),
                    path=path,
                    canvas_width=data.get("canvas_width", 1920),
                    canvas_height=data.get("canvas_height", 1080),
                    characters=data.get("characters", ["main"]),
                    onion_enabled=data.get("onion_enabled", False),
                    onion_before=data.get("onion_before", 2),
                    onion_after=data.get("onion_after", 1),
                    onion_opacity_before=data.get("onion_opacity_before", 0.3),
                    onion_opacity_after=data.get("onion_opacity_after", 0.2),
                )
                
                # Load shot
                if "shot" in data:
                    shot_data = data["shot"]
                    shot = Shot(
                        name=shot_data.get("name", "shot1"),
                        duration=shot_data.get("duration", 24),
                        current_frame=shot_data.get("current_frame", 1),
                        active_layer_idx=shot_data.get("active_layer_idx", 0),
                    )
                    
                    for layer_data in shot_data.get("layers", []):
                        layer = Layer(
                            name=layer_data["name"],
                            visible=layer_data.get("visible", True),
                            locked=layer_data.get("locked", False),
                            _next_key_id=layer_data.get("_next_key_id", 1),
                        )
                        
                        for kf_data in layer_data.get("keyframes", []):
                            key_id = kf_data["id"]
                            frame = kf_data["frame"]
                            
                            # Load keyframe data
                            key_path = f"keyframes/{layer.name}_{key_id}.bin"
                            try:
                                blob = zf.read(key_path)
                                kf = Keyframe.from_bytes(
                                    blob, 
                                    project.canvas_width, 
                                    project.canvas_height,
                                    frame,
                                    key_id
                                )
                            except KeyError:
                                # No data file, create empty keyframe
                                kf = Keyframe(frame=frame, _id=key_id)
                            
                            layer.keyframes.append(kf)
                        
                        shot.layers.append(layer)
                    
                    project.shot = shot
                
                return project
                
        except Exception as e:
            print(f"Error loading project: {e}")
            return None
    
    @classmethod
    def create(cls, path: Path, name: str = None, 
               characters: list[str] = None,
               canvas_width: int = 1920, 
               canvas_height: int = 1080) -> Project:
        """Create a new project."""
        if name is None:
            name = path.stem
        
        project = cls(
            name=name,
            path=path,
            canvas_width=canvas_width,
            canvas_height=canvas_height,
            characters=characters or ["main"],
        )
        
        # Create initial shot with default layers
        shot = Shot(name="shot1", duration=24)
        shot.create_default_layers(project.characters)
        
        # Create initial keyframe on each layer at frame 1
        for layer in shot.layers:
            layer.insert_keyframe(1, project.canvas_size, duplicate=False)
        
        project.shot = shot
        project.save()
        
        return project


# =============================================================================
# Helper
# =============================================================================

def load_or_create_project(path: Path) -> Project:
    """Load existing project or create new one."""
    path = Path(path)
    
    # Ensure .reskia extension
    if path.suffix != ".reskia":
        path = path.with_suffix(".reskia")
    
    if path.exists():
        return Project.load(path)
    else:
        return Project.create(path)
