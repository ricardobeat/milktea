# 3D Minecraft Demo

A 3D Minecraft-inspired demo for the Bubble Tea C3 TUI framework. It features a procedurally generated island, 3D voxel-based rendering, and first-person controls.

## Features

- **3D Voxel Engine**: Uses quad-based face rasterization with perspective projection and depth buffering.
- **High Resolution**: Employs the `xray` half-block technique (`▀`) to double the vertical resolution in the terminal.
- **Dynamic Lighting**: World-space normal-based shading for realistic block depth and shadows.
- **First-Person Controls**: Mouse-controlled look (Yaw/Pitch) and keyboard-based movement.
- **Interaction**: Minecraft-style block mining with a pickaxe HUD and swing animation.
- **Atmospheric Rendering**: Dynamic horizon and sky gradient that reacts to camera pitch.
- **Performance**: neighbor-aware occlusion culling skips rendering internal block faces.

## Controls

| Key | Action |
|-----|--------|
| **W/A/S/D** | Move player forward/left/backward/right |
| **Mouse Move** | Look around (Rotate camera) |
| **Left Click / Space** | Swing pickaxe / Mine block in front |
| **Q / ESC** | Quit demo |

## Running the Demo

Ensure you have the `c3c` compiler installed, then run:

```bash
cd bubbletea-c3
c3c build examples/minecraft
./out/examples/minecraft
```
