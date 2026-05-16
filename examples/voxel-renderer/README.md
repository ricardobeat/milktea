# Voxel Renderer Example

A real-time 3D voxel renderer in the terminal. Displays the word "tea" extruded to 3 blocks thickness, rotating continuously in 3D space using perspective projection.

## Features

- **3D text**: Each character in "tea" is a 3×3×3 voxel block
- **Continuous rotation**: Animates on every frame with smooth rotation around x, y, and z axes
- **Perspective projection**: Projects 3D coordinates to 2D screen space with depth
- **Depth sorting**: Renders closer voxels on top (painter's algorithm)
- **Real-time animation**: Uses `tea::tick()` for frame updates

## How It Works

### 3D Math

**Rotations**: Three rotation matrices applied sequentially:
```c3
p = p.rotate_x(angle_x);
p = p.rotate_y(angle_y);
p = p.rotate_z(angle_z);
```

Each rotation uses the standard 3D rotation matrix (sine/cosine).

**Perspective Projection**: Simple perspective with distance parameter:
```c3
scale = distance / (distance + z);
screen_x = x * scale;
screen_y = y * scale;
```

Points further away (larger z) scale down, creating the illusion of depth.

### Data Structure

```c3
struct Vec3 {
    float x, y, z;
}

struct Voxel {
    Vec3 pos;       // 3D position
    char char_val;  // character to display
}
```

### Voxel Generation

`create_text_voxels()` builds 27 voxels per character (3×3×3 grid):
- Text is centered horizontally: `start_x = -(text.len / 2)`
- Each character spans 1 unit wide, 3 units tall, 3 units deep
- All voxels display the same character (the letter itself)

### Rendering Pipeline

1. **Rotation**: Transform each voxel position by the three rotation angles
2. **Projection**: Convert 3D positions to 2D screen coordinates with depth values
3. **Depth sorting**: For each screen position, keep only the closest voxel (smallest z)
4. **Canvas**: Write characters to a 2D character array
5. **Display**: Render the canvas with a frame counter

### Animation

- **Frame counter**: Increments on each tick
- **Rotation rates**:
  - X-axis: `frame * 0.02` (slowest, ~90° per 45 frames)
  - Y-axis: `frame * 0.03` (medium, ~90° per 30 frames)
  - Z-axis: `frame * 0.01` (fastest)

Adjust these multipliers to speed up or slow down rotation.

## Building

```bash
cd examples/voxel-renderer
c3c run
```

You should see "tea" rotating continuously in the center of your terminal.

## Customization Ideas

- **Different text**: Change the string in `create_text_voxels()`
- **More voxels per char**: Adjust the nested loop ranges (currently -1 to 1 vertically)
- **Different characters**: Use different `char_val` per voxel layer for striped effects
- **Colors**: Extend `format_diff_line()` logic to add lipgloss colors based on depth or axis
- **Wireframe mode**: Only draw voxel edges instead of solid characters
- **Multiple objects**: Create helper functions to generate other shapes (cubes, pyramids)
- **Mouse control**: Add mouse input to rotate via `tea::MsgKind.MOUSE`
- **Faster rendering**: Replace the 2D character array with a more efficient sparse structure for large scenes
- **Depth cues**: Use different characters for different depth ranges (e.g., `@` for closest, `.` for farthest)

## Key Techniques Demonstrated

- **3D vector math**: Rotation matrices, perspective projection
- **Fixed-size arrays**: `char[256][80]` for the rendering canvas
- **Depth buffer**: `float[256][80]` for painter's algorithm (depth sorting)
- **Trigonometry**: `math::cos()`, `math::sin()` for rotations
- **Real-time animation**: Frame counter with `tea::tick()`
- **Method chaining**: `.rotate_x().rotate_y().rotate_z().project()`
- **Vim-style controls**: `q` to quit
