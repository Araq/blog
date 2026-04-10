==================================
  Fog Frog Wars
==================================


Fog Frog Wars
=============

*2026-04-01*

We developed a custom 3D engine in Nim called **NimLumen**! We use this technology to develop **Fog-Frog-Wars**, a first person
shooter where you try to find the frogs in the fog -- to kill them!

The next evolution in amphibian tactical combat
-----------------------------------------------

   "We wanted to ask: what if Dark Souls, but with frogs?"
   -- Andreas Rumpf

Fog-Frog-Wars is an immersive first-person tactical shooter set in a procedurally generated medieval wilderness. Hunt elusive frogs concealed within NimLumen's industry-leading volumetric fog system — each encounter a test of patience, spatial awareness, and raw frog-finding instinct.

Key features:

* **Advanced frog AI** powered by a multi-agent behavior tree with emergent camouflage response and threat assessment
* **Dynamic fog simulation** — real-time Mie scattering means no two frog hunts feel the same
* **Photo-realistic frog rendering** with per-pore subsurface scattering and procedural wetness shaders
* **Haptic frog feedback** — feel every croak through your controller's low-frequency rumble layer
* **Asymmetric multiplayer:** one player is the frog
* **Permadeath roguelite progression** — when you die, you become a frog
* **Accessibility options:** colorblind mode, reduced fog density, frog radar (Easy), no frog radar (Nightmare)
* **Ray-traced croaking** — sound propagation fully simulated through the fog volume
* **Early Access Q3 2026** — wishlists open now

Exclusive trailer
-----------------

.. raw:: html

   <video controls loop style="width:100%; max-width:600px;" poster="https://nim-lang.org/araq/videos/fogfrog.png"
          onclick="this.play()">
     <source src="https://nim-lang.org/araq/videos/VID_20251212_121150.mp4" type="video/mp4">
     Your browser does not support the video tag.
   </video>



NimLumen
--------

Next-generation photorealistic rendering engine — written entirely in Nim

Features:

* **Spectral path tracing** with full wavelength-dependent light transport and dispersion simulation
* **Sparse Voxel Octree Global Illumination (SVOGI)** for real-time infinite-bounce indirect lighting
* **Physically Based Rendering (PBR)** pipeline with a multi-lobe BRDF and energy conservation at all roughness levels
* **Subsurface scattering (SSS)** with a screen-space diffusion profile for organic materials (moss, bark, leaves)
* **Procedural foliage system** using stochastic LOD billboarding and wind-responsive skeletal simulation
* **Volumetric atmospheric scattering** via a single-pass Rayleigh/Mie integration on the GPU
* **Virtual Shadow Maps (VSM)** with 16k texel density and automatic page caching for infinite-range directional shadows
* **Temporal Anti-Aliasing (TAA)** with a neighborhood-clamped history buffer and sub-pixel jitter reprojection
* **AI-assisted supersampling upscaler** trained on Nim-native render targets (4x upscale, <2ms overhead)
* **Nanite-inspired micro-polygon geometry streaming** with visibility-driven cluster culling and on-the-fly LOD tessellation
* **Screen-Space Ambient Occlusion (SSAO)** augmented with ray-marched bent normals for contact hardening
* **HDR display pipeline** with filmic tone mapping and automatic scene-referred exposure adaptation

The tech will be open-sourced under the MIT license after the game's release!

Coming soon!
