# Project5-WebGPU-Gaussian-Splat-Viewer

**University of Pennsylvania, CIS 565: GPU Programming and Architecture, Project 5**

* Daniel Chen
* Tested on: Chromium 144 - Windows 11, AMD Ryzen 7 8845HS w/ Radeon 780M Graphics (3.80 GHz), RTX 4070 notebook

This project is a WebGPU implementation of point cloud and Gaussian splat rendering.

Gaussian splat rendering is a rendering technique that depicts a set of oriented, scaled, colored points as small, volumetric Gaussian distribuions in 3D space. This model is is often used in photogrammetry, recreatng 3D scenes from photo data, by gradually making the set of points converge onto a progressively more accurate depiction of a scene. The resulting data can be stored in a `.ply` file ([samples](https://drive.google.com/drive/folders/1KOoKk4plvl720-nQEiqLcuTCMFizt0cc?usp=sharing)), which, alongside a JSON file with camera data, can be read by this web app and rendered in real time as either a point cloud (only centers are drawn, which is faster since there is less to render, letting you visualize the scene through the density of points) or as the full set of Gaussian splats.

### Live Demo

https://enamchae.github.io/Project5-WebGPU-Gaussian-Splat-Viewer/

[![](./images/cover.png)](https://enamchae.github.io/Project5-WebGPU-Gaussian-Splat-Viewer/)

### Demo Video/GIF

https://github.com/user-attachments/assets/e26cffa1-f91a-46f7-9415-3bf389344195

### Performance

For many scenes, there is a load time of several seconds while splat data is read from the `.ply` file. The below analysis only deals with the render time after all this data has been loaded.

#### Preprocessing workgroup size
For the bonzai scene above at the default angle, using the Gaussian splat renderer at the default splat scale, it is difficult to compare different workgroup sizes for the preprocessing compute shader, as adjusting the workgroup size too low causes my GPU to hang. Workgroup sizes of 64 or below hang immediately on the bonzai scene, 128 remains steady at around 7 to 28 ms/frame but hangs as more splats are moved onto the screen, and 256 has no issues while achieving a similar framerate. The workgroup size can be decreased lower especially when sorting is disabled, so the number of workgroup dispatches needed to perform radix sort may cause issues at lower workgroup sizes. When sorting is disabled, the framerate hovers in the 6 to 28 ms/frame range at all workgroup sizes between 16 and 256.

#### Half-precision packing
To save on some additional memory per splat, some `f32` fields on the `Splat` struct are compressed into paired-up `f16` fields instead. With this, we can drop down from 48 bytes to 32 bytes per `Splat` (but we have too many fields to reach 16 bytes), which can be beneficial seeing as many splats will make up a scene. The render time remains roughly the same.

#### View frustum culling
In the preprocess step, we flag splats as being culled if they lie outside the camera's view frustum plus a 10% margin in either dimension. On the bicycle scene above, the benefits of view frustum culling are noticeable especially when a significant portion of the model is off-screen. At roughly the angle pictured below, the render time is about 28 ms/frame with view frustum culling and about 50 ms/frame without, but both remain at about 70 ms/frame with the full scene.

![](./images/occluded.png)

#### Effects of scene complexity
There is a noticeable performance difference between the bonzai and bicycle scenes above, so the number of splats likely makes a difference. In particular, rendering the entire bonzai scene takes around 6 to 21 ms/frame whereas the bicycle scene can take around 70 ms/frame, even if they take a similar proportion of the frame.

|Bonzai|Bicycle|
|-|-|
|![](./images/bonzaiframe.png)|![](./images/bicycleframe.png)|

The cleaned bicycle scene above has about 4 times as many splats (1 063 091) as the bonzai scene (272 956), which could mean more threads have to be run in sequence in the preprocessing and sorting steps. An additional bottleneck could be the handling of the atomic sort count, which would require each thread encountering the `atomicAdd` to be executed in sequence. One way to avoid this could be to use a prefix sum instead of a linear addition, achieving an `O(\log(n))` ideally parallel time complexity rather than `O(n)`.


### Credits

- [Vite](https://vitejs.dev/)
- [tweakpane](https://tweakpane.github.io/docs//v3/monitor-bindings/)
- [stats.js](https://github.com/mrdoob/stats.js)
- [wgpu-matrix](https://github.com/greggman/wgpu-matrix)
- Special Thanks to: Shrek Shao (Google WebGPU team) & [Differential Guassian Renderer](https://github.com/graphdeco-inria/diff-gaussian-rasterization)
