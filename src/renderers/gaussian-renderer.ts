import { PointCloud } from '../utils/load';
import preprocessWGSL from '../shaders/preprocess.wgsl';
import renderWGSL from '../shaders/gaussian.wgsl';
import { get_sorter,c_histogram_block_rows,C } from '../sort/sort';
import { Renderer } from './renderer';

export interface GaussianRenderer extends Renderer {
  setGaussianMultiplier: (value: number) => void,
}

// Utility to create GPU buffers
const createBuffer = (
  device: GPUDevice,
  label: string,
  size: number,
  usage: GPUBufferUsageFlags,
  data?: ArrayBuffer | ArrayBufferView
) => {
  const buffer = device.createBuffer({ label, size, usage });
  if (data) device.queue.writeBuffer(buffer, 0, data);
  return buffer;
};

export default function get_renderer(
  pc: PointCloud,
  device: GPUDevice,
  presentation_format: GPUTextureFormat,
  camera_buffer: GPUBuffer,
): GaussianRenderer {

  const sorter = get_sorter(pc.num_points, device);
  
  // ===============================================
  //            Initialize GPU Buffers
  // ===============================================

  const nulling_data = new Uint32Array([0]);

  // ===============================================
  //    Create Compute Pipeline and Bind Groups
  // ===============================================
  
  // Create explicit bind group layout for sort data
  const sortLayout = device.createBindGroupLayout({
    label: "sort layout",
    entries: [
      {
        binding: 0,
        visibility: GPUShaderStage.COMPUTE,
        buffer: {
          type: "storage",
        }
      },
      {
        binding: 1,
        visibility: GPUShaderStage.COMPUTE,
        buffer: {
          type: "storage",
        }
      },
      {
        binding: 2,
        visibility: GPUShaderStage.COMPUTE,
        buffer: {
          type: "storage",
        }
      },
      {
        binding: 3,
        visibility: GPUShaderStage.COMPUTE,
        buffer: {
          type: "storage",
        }
      },
    ],
  });

  const gaussiansLayoutPreprocess = device.createBindGroupLayout({
    label: "gaussians layout",
    entries: [
      {
        binding: 0,
        visibility: GPUShaderStage.COMPUTE,
        buffer: {
          type: "read-only-storage",
        },
      },
      {
        binding: 1,
        visibility: GPUShaderStage.COMPUTE,
        buffer: {
          type: "storage",
        },
      },
      {
        binding: 2,
        visibility: GPUShaderStage.COMPUTE,
        buffer: {
          type: "read-only-storage",
        },
      },
    ],
  });

  const gaussiansLayoutRender = device.createBindGroupLayout({
    label: "gaussians layout",
    entries: [
      {
        binding: 0,
        visibility: GPUShaderStage.VERTEX,
        buffer: {
          type: "read-only-storage",
        },
      },
      {
        binding: 1,
        visibility: GPUShaderStage.VERTEX,
        buffer: {
          type: "read-only-storage",
        },
      },
      {
        binding: 2,
        visibility: GPUShaderStage.VERTEX,
        buffer: {
          type: "read-only-storage",
        },
      },
    ],
  });
  const uniformsLayout = device.createBindGroupLayout({
    label: "gaussian uniforms layout",
    entries: [
      {
        binding: 0,
        visibility: GPUShaderStage.COMPUTE,
        buffer: {
          type: "uniform",
        },
      },
    ],
  });

  const cameraLayout = device.createBindGroupLayout({
    label: "gaussian camera layout",
    entries: [
      {
        binding: 0,
        visibility: GPUShaderStage.COMPUTE | GPUShaderStage.VERTEX,
        buffer: {
          type: "uniform",
        },
      },
    ],
  });

  const preprocessLayout = device.createPipelineLayout({
    label: "preprocess layout",
    bindGroupLayouts: [sortLayout, gaussiansLayoutPreprocess, uniformsLayout, cameraLayout],
  });

  const renderLayout = device.createPipelineLayout({
    label: "gaussian render layout",
    bindGroupLayouts: [cameraLayout, gaussiansLayoutRender],
  });

  const preprocess_pipeline = device.createComputePipeline({
    label: 'preprocess',
    layout: preprocessLayout,
    compute: {
      module: device.createShaderModule({ code: preprocessWGSL }),
      entryPoint: 'preprocess',
      constants: {
        workgroupSize: C.histogram_wg_size,
        sortKeyPerThread: c_histogram_block_rows,
      },
    },
  });

  const sort_bind_group = device.createBindGroup({
    label: 'sort',
    layout: sortLayout,
    entries: [
      { binding: 0, resource: { buffer: sorter.sort_info_buffer } },
      { binding: 1, resource: { buffer: sorter.ping_pong[0].sort_depths_buffer } },
      { binding: 2, resource: { buffer: sorter.ping_pong[0].sort_indices_buffer } },
      { binding: 3, resource: { buffer: sorter.sort_dispatch_indirect_buffer } },
    ],
  });


  // ===============================================
  //    Create Render Pipeline and Bind Groups
  // ===============================================
  const splatBuffer = device.createBuffer({
    label: "splat buffer",
    size: pc.num_points * 48,
    usage: GPUBufferUsage.STORAGE,
  });

  const uniformsBuffer = device.createBuffer({
    label: "uniforms buffer",
    size: 4,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });


  const render_shader = device.createShaderModule({code: renderWGSL});
  const render_pipeline = device.createRenderPipeline({
    label: 'render',
    layout: renderLayout,
    vertex: {
      module: render_shader,
      entryPoint: 'vs_main',
    },
    fragment: {
      module: render_shader,
      entryPoint: 'fs_main',
      targets: [{
        format: presentation_format,
        blend: {
          color: {
            srcFactor: "one",
            dstFactor: "one-minus-src-alpha",
            operation: "add",
          },
          alpha: {
            srcFactor: "one",
            dstFactor: "one-minus-src-alpha",
            operation: "add",
          },
        },
      }],
    },
    primitive: {
      topology: 'triangle-list',
    },
  });

  const camera_bind_group = device.createBindGroup({
    label: 'point cloud camera',
    layout: cameraLayout,
    entries: [{binding: 0, resource: { buffer: camera_buffer }}],
  });

  const gaussianGroupPreprocess = device.createBindGroup({
    label: 'point cloud gaussians',
    layout: gaussiansLayoutPreprocess,
    entries: [
      {binding: 0, resource: { buffer: pc.gaussian_3d_buffer }},
      {binding: 1, resource: { buffer: splatBuffer }},
      {binding: 2, resource: { buffer: pc.sh_buffer }},
    ],
  });


  const gaussianGroupRender = device.createBindGroup({
    label: 'point cloud gaussians',
    layout: gaussiansLayoutRender,
    entries: [
      {binding: 0, resource: { buffer: pc.gaussian_3d_buffer }},
      {binding: 1, resource: { buffer: splatBuffer }},
      {binding: 2, resource: { buffer: pc.sh_buffer }},
    ],
  });

  const uniformsBindGroup = device.createBindGroup({
    label: "preprocess settings bind group",
    layout: uniformsLayout,
    entries: [
      {binding: 0, resource: {buffer: uniformsBuffer}},
    ],
  });

  // ===============================================
  //    Command Encoder Functions
  // ===============================================
  

  // ===============================================
  //    Return Render Object
  // ===============================================
  return {
    frame: (encoder: GPUCommandEncoder, texture_view: GPUTextureView) => {
      sorter.sort(encoder);

      const computePass = encoder.beginComputePass({
        label: "Gaussian preprocess compute pass",
      });
      computePass.setPipeline(preprocess_pipeline);
      computePass.setBindGroup(0, sort_bind_group);
      computePass.setBindGroup(1, gaussianGroupPreprocess);
      computePass.setBindGroup(2, uniformsBindGroup);
      computePass.setBindGroup(3, camera_bind_group)
      computePass.dispatchWorkgroups(Math.ceil(pc.num_points / C.histogram_wg_size));
      computePass.end();
      
      const renderPass = encoder.beginRenderPass({
        label: 'Gaussian render pass',
        colorAttachments: [
          {
            view: texture_view,
            loadOp: 'clear',
            storeOp: 'store',
          }
        ],
      });
      renderPass.setPipeline(render_pipeline);
      renderPass.setBindGroup(0, camera_bind_group);
      renderPass.setBindGroup(1, gaussianGroupRender);
  
      renderPass.draw(6, pc.num_points);
      renderPass.end();

    },
    camera_buffer,
    setGaussianMultiplier: (value: number) => {
      device.queue.writeBuffer(uniformsBuffer, 0, new Float32Array([value]));
    },
  };
}
