import os from 'os';
import { readFileSync, createReadStream, existsSync } from 'fs';
import { mkdir, writeFile, stat, unlink, rename } from 'fs/promises';
import { join } from 'path';
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';

// ============================================
// CONSTANTS & IDENTITY
// ============================================
const COMFY_PORT = 8188;
const COMFY_HOST = `http://127.0.0.1:${COMFY_PORT}`;
const WORKFLOW_PATH = join(process.cwd(), 'flux.2.klein.json');

// ComfyUI directory resolution (handles symlinked or local /workspace mounts)
const BASE_COMFY_DIR = existsSync('/app/ComfyUI') ? '/app/ComfyUI' : join(process.cwd(), 'ComfyUI');
const INPUT_DIR = join(BASE_COMFY_DIR, 'input');
const OUTPUT_DIR = join(BASE_COMFY_DIR, 'output');

// Identity strictly derived from the OS Hostname & static secret
const MACHINE_ID = os.hostname();
const WORKER_API_SECRET = process.env.WORKER_API_SECRET;

// Discovery cache: null = unprobed, false = not a hyperstack instance, string/number = VM ID
let HYPERSTACK_VM_ID = null;

// Track active background uploads to prevent shutdown race conditions
const active_uploads = new Set();

// Backend Configuration
const API_BASE_URL = process.env.API_BASE_URL || 'https://api.runltx.com';
const JOB_TYPE = process.env.JOB_TYPE || 'generate';
const MODEL_TYPE = process.env.MODEL_TYPE || 'image-edit';
const POLL_INTERVAL_SECONDS = parseInt(process.env.POLL_INTERVAL_SECONDS, 10) || 1;
const MAX_EMPTY_POLLS = parseInt(process.env.MAX_EMPTY_POLLS, 10) || 3;
const MAX_RETRY_COUNT = parseInt(process.env.MAX_RETRY_COUNT, 10) || 2;

// Hyperstack API Configuration (Optional, for bare-metal/VM self-hibernation)
const HYPERSTACK_API_URL = process.env.HYPERSTACK_API_URL || 'https://infrahub-api.nexgencloud.com/v1';
const HYPERSTACK_API_KEY = process.env.HYPERSTACK_API_KEY;

// R2 Storage Client Configuration
const R2_ACCOUNT_ID = process.env.R2_ACCOUNT_ID;
const R2_ACCESS_KEY_ID = process.env.R2_ACCESS_KEY_ID;
const R2_SECRET_ACCESS_KEY = process.env.R2_SECRET_ACCESS_KEY;
const R2_BUCKET_NAME = process.env.R2_BUCKET_NAME;
const R2_CDN_URL = process.env.R2_CDN_URL;

console.log('====================================================');
console.log(`[Config] Machine ID:        ${MACHINE_ID}`);
console.log(`[Config] API Endpoint:      ${API_BASE_URL}`);
console.log(`[Config] Model Target:      ${JOB_TYPE}/${MODEL_TYPE}`);
console.log(`[Config] Comfy Host:        ${COMFY_HOST}`);
console.log(`[Config] Comfy Output Dir:  ${OUTPUT_DIR}`);
console.log(`[Config] R2 Account ID:     ${R2_ACCOUNT_ID ? 'Configured (' + R2_ACCOUNT_ID.slice(0, 6) + '...)' : 'MISSING'}`);
console.log(`[Config] R2 Bucket:         ${R2_BUCKET_NAME || 'MISSING'}`);
console.log(`[Config] R2 CDN URL:        ${R2_CDN_URL || 'MISSING'}`);
console.log('====================================================');

if (!R2_ACCOUNT_ID || !R2_ACCESS_KEY_ID || !R2_SECRET_ACCESS_KEY || !R2_BUCKET_NAME) {
  console.error('[CRITICAL] Missing required R2 environment variables. Uploads will fail!');
}

const s3_client = new S3Client({
  region: 'auto',
  endpoint: `https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
  credentials: {
    accessKeyId: R2_ACCESS_KEY_ID || '',
    secretAccessKey: R2_SECRET_ACCESS_KEY || '',
  },
});

// ============================================
// Helper Functions & Lifecycle Control
// ============================================
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const format_prompt_preview = (text, maxLength = 100) => {
  if (!text) return '(empty)';
  const singleLine = text.replace(/\s+/g, ' ').trim();
  if (singleLine.length <= maxLength) return `"${singleLine}"`;
  return `"${singleLine.slice(0, maxLength)}..." [${singleLine.length} chars]`;
};

const is_modal_runtime = () => {
  return Boolean(
    process.env.MODAL_TASK_ID ||
    process.env.MODAL_IS_REMOTE ||
    process.env.MODAL_ENVIRONMENT
  );
};

const get_api_headers = () => ({
  'worker-auth': WORKER_API_SECRET,
  'x-machine-id': MACHINE_ID,
  'content-type': 'application/json'
});

const get_hyperstack_headers = () => ({
  'api_key': HYPERSTACK_API_KEY,
  'content-type': 'application/json'
});

// ============================================
// Cloud Discovery & Teardown Handlers
// ============================================
const resolve_hyperstack_vm_id = async () => {
  if (HYPERSTACK_VM_ID !== null) return HYPERSTACK_VM_ID;

  if (is_modal_runtime() || !HYPERSTACK_API_KEY) {
    HYPERSTACK_VM_ID = false;
    return null;
  }

  try {
    console.log(`[Hyperstack] Checking if hostname '${MACHINE_ID}' exists in Hyperstack account...`);
    const res = await fetch(`${HYPERSTACK_API_URL}/core/virtual-machines`, {
      method: 'GET',
      headers: get_hyperstack_headers()
    });

    if (!res.ok) {
      HYPERSTACK_VM_ID = false;
      return null;
    }

    const data = await res.json();
    const instances = data.instances || [];
    const match = instances.find((vm) => vm.name?.toLowerCase() === MACHINE_ID.toLowerCase());

    if (!match) {
      console.log(`[Platform Detection] Host '${MACHINE_ID}' not in Hyperstack inventory. Disabling Hyperstack hibernation.`);
      HYPERSTACK_VM_ID = false;
      return null;
    }

    HYPERSTACK_VM_ID = match.id;
    console.log(`[Platform Detection] Hyperstack VM verified (ID: ${HYPERSTACK_VM_ID})`);
    return HYPERSTACK_VM_ID;
  } catch (err) {
    console.warn('[Hyperstack Discovery Failed]:', err.message);
    HYPERSTACK_VM_ID = false;
    return null;
  }
};

const hibernate_vm = async () => {
  try {
    const vm_id = await resolve_hyperstack_vm_id();
    if (!vm_id) throw new Error('Cannot hibernate: Hyperstack VM ID is missing.');

    console.log(`[Hibernate] Requesting hibernation for VM ${vm_id}...`);
    const url = `${HYPERSTACK_API_URL}/core/virtual-machines/${vm_id}/hibernate?retain_ip=true`;
    const res = await fetch(url, {
      method: 'GET',
      headers: get_hyperstack_headers()
    });

    if (!res.ok) {
      const err_text = await res.text();
      throw new Error(`HTTP ${res.status}: ${err_text}`);
    }

    const data = await res.json();
    console.log('[Hibernate] VM hibernation successfully initiated:', JSON.stringify(data));
    return data;
  } catch (err) {
    console.error('[Hibernate Error]:', err.message);
    return null;
  }
};

const flush_pending_uploads = async () => {
  if (active_uploads.size > 0) {
    console.log(`[Worker] Waiting for ${active_uploads.size} background upload(s) to complete before teardown...`);
    await Promise.allSettled(Array.from(active_uploads));
    console.log('[Worker] All background uploads resolved.');
  }
};

const handle_inactivity_shutdown = async () => {
  console.log('[Worker] Inactivity limit reached. Initiating teardown...');
  await flush_pending_uploads();

  if (is_modal_runtime()) {
    console.log('[Teardown: Modal] Serverless task finished. Exiting container.');
    process.exit(0);
  }

  const vm_id = await resolve_hyperstack_vm_id();
  if (vm_id) {
    console.log(`[Teardown: Hyperstack] Hibernating Hyperstack VM ${vm_id}...`);
    await hibernate_vm();
    process.exit(0);
  }

  console.log('[Teardown: Generic] Exiting worker process.');
  process.exit(0);
};

// ============================================
// Central Backend API Handshakes
// ============================================
const poll_for_job = async () => {
  try {
    const url = `${API_BASE_URL}/v1/worker/get?job_type=${JOB_TYPE}&model=${MODEL_TYPE}`;
    const response = await fetch(url, {
      method: 'GET',
      headers: get_api_headers()
    });

    if (response.status === 404) return null;
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`);

    return await response.json();
  } catch (err) {
    console.error('[API Poll Error]:', err.message);
    return null;
  }
};

const complete_job = async (job_id, output_url, generation_time_sec) => {
  const response = await fetch(`${API_BASE_URL}/v1/worker/complete`, {
    method: 'POST',
    headers: get_api_headers(),
    body: JSON.stringify({ job_id, output_url, generation_time_sec })
  });

  if (!response.ok) {
    const err_text = await response.text();
    throw new Error(`API complete error: HTTP ${response.status} - ${err_text}`);
  }
  return await response.json();
};

const fail_job = async (job_id, error_message) => {
  console.log(`[API Handshake] Reporting failure for job '${job_id}': ${error_message}`);
  const response = await fetch(`${API_BASE_URL}/v1/worker/fail`, {
    method: 'POST',
    headers: get_api_headers(),
    body: JSON.stringify({ job_id, error_message })
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`);
  return await response.json();
};

// ============================================
// ComfyUI Engine Interface
// ============================================
const wait_for_comfy_ready = async () => {
  console.log('[ComfyUI] Probing server readiness on port 8188...');
  while (true) {
    try {
      const res = await fetch(`${COMFY_HOST}/history`);
      if (res.ok) {
        console.log('[ComfyUI] Server online and responsive.');
        break;
      }
    } catch (_) {}
    await sleep(500);
  }
};

const execute_workflow = async (workflow, job_id) => {
  console.log(`[ComfyUI] Submitting prompt graph for job '${job_id}'...`);
  const response = await fetch(`${COMFY_HOST}/prompt`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ prompt: workflow }),
  });

  if (!response.ok) {
    const err_text = await response.text();
    throw new Error(`ComfyUI prompt rejected: HTTP ${response.status} - ${err_text}`);
  }

  const { prompt_id } = await response.json();
  const start_time = Date.now();

  while (true) {
    await sleep(500);
    const history_res = await fetch(`${COMFY_HOST}/history/${prompt_id}`);
    if (history_res.ok) {
      const history_data = await history_res.json();
      const job_history = history_data[prompt_id];

      if (job_history) {
        const duration = (Date.now() - start_time) / 1000;

        if (job_history.status?.status_str === 'error') {
          const messages = job_history.status.messages || [];
          throw new Error(`ComfyUI execution error: ${JSON.stringify(messages)}`);
        }

        const outputs = job_history.outputs || {};
        for (const nodeId in outputs) {
          const nodeOutput = outputs[nodeId];
          if (nodeOutput.images && nodeOutput.images.length > 0) {
            const img = nodeOutput.images[0];
            const subfolder = img.subfolder ? `${img.subfolder}/` : '';
            const output_path = join(OUTPUT_DIR, `${subfolder}${img.filename}`);
            return { output_path, duration };
          }
        }

        throw new Error(`ComfyUI finished prompt ${prompt_id} but output node produced no image references.`);
      }
    }
  }
};

// ============================================
// Image IO & Storage
// ============================================
const download_image = async (url, filename) => {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Input download failed: HTTP ${res.status} (${res.statusText})`);

  const buffer = await res.arrayBuffer();
  await mkdir(INPUT_DIR, { recursive: true });
  const image_path = join(INPUT_DIR, filename);
  await writeFile(image_path, Buffer.from(buffer));
  return image_path;
};

const upload_to_r2 = async (file_path, job_id) => {
  if (!existsSync(file_path)) {
    throw new Error(`File not found for R2 upload at path: ${file_path}`);
  }

  const ext = file_path.endsWith('.png') ? 'png' : file_path.endsWith('.webp') ? 'webp' : 'jpg';
  const key = `edits/${job_id}.${ext}`;
  const contentType = ext === 'png' ? 'image/png' : ext === 'webp' ? 'image/webp' : 'image/jpeg';
  const file_stream = createReadStream(file_path);

  await s3_client.send(new PutObjectCommand({
    Bucket: R2_BUCKET_NAME,
    Key: key,
    Body: file_stream,
    ContentType: contentType,
  }));

  return `${R2_CDN_URL}/${key}`;
};

// ============================================
// Background Upload Task Runner
// ============================================
const upload_and_complete_async = async (job_id, isolated_path, input_path, duration) => {
  try {
    const r2_url = await upload_to_r2(isolated_path, job_id);
    await complete_job(job_id, r2_url, duration);
    console.log(`[Job ${job_id}] Background upload & complete finished successfully.`);
  } catch (err) {
    console.error(`[Job ${job_id}] Background upload/complete failed:`, err.message);
    try { await fail_job(job_id, err.message); } catch (_) {}
  } finally {
    if (isolated_path) {
      try { await unlink(isolated_path); } catch (_) {}
    }
    if (input_path) {
      try { await unlink(input_path); } catch (_) {}
    }
  }
};

// ============================================
// Main Job Processing
// ============================================
const process_job = async (job_data) => {
  const { job_id, image_url, prompt } = job_data;
  let retry_count = 0;
  let input_path = null;

  console.log(`\n====================================================`);
  console.log(`[Job ${job_id}] Processing job request`);
  console.log(`[Job ${job_id}] Prompt: ${format_prompt_preview(prompt)}`);
  console.log(`====================================================`);

  while (retry_count < MAX_RETRY_COUNT) {
    try {
      const input_filename = `${job_id}_input.jpg`;
      input_path = await download_image(image_url, input_filename);

      const workflow = JSON.parse(readFileSync(WORKFLOW_PATH, 'utf-8'));

      // Map workflow node inputs
      workflow["76"].inputs.image = input_filename;
      const seed = Math.floor(Math.random() * 1000000000000000);
      workflow["75:73"].inputs.noise_seed = seed;
      if (prompt) {
        workflow["75:74"].inputs.text = prompt;
      }

      // Force CFG to 1.0 for single-pass FLUX guidance
      if (workflow["75:63"] && workflow["75:63"].inputs) {
        workflow["75:63"].inputs.cfg = 1.0;
      }

      // Execute in ComfyUI
      const { output_path: generated_file, duration } = await execute_workflow(workflow, job_id);

      // 1. Rename to isolate file immediately
      const ext = generated_file.endsWith('.png') ? 'png' : generated_file.endsWith('.webp') ? 'webp' : 'jpg';
      const isolated_path = join(OUTPUT_DIR, `uploading_${job_id}.${ext}`);
      await rename(generated_file, isolated_path);

      console.log(`[Job ${job_id}] Rendered in ${duration.toFixed(2)}s. Offloaded upload to background.`);

      // 2. Fire and track background upload (GPU freed immediately)
      const upload_task = upload_and_complete_async(job_id, isolated_path, input_path, duration);
      active_uploads.add(upload_task);
      upload_task.finally(() => active_uploads.delete(upload_task));

      // 3. Immediately return so worker takes next job
      return true;
    } catch (err) {
      retry_count++;
      console.error(`[Job ${job_id}] Attempt ${retry_count}/${MAX_RETRY_COUNT} failed:`, err.message);

      if (retry_count >= MAX_RETRY_COUNT) {
        try { await fail_job(job_id, err.message); } catch (_) {}
        if (input_path) {
          try { await unlink(input_path); } catch (_) {}
        }
        return false;
      }

      await sleep(retry_count * 2000);
    }
  }
  return false;
};

const worker_loop = async () => {
  console.log(`[Worker] Daemon started on machine: ${MACHINE_ID}`);

  if (!WORKER_API_SECRET) {
    console.error('[Worker Fatal] WORKER_API_SECRET environment variable is missing.');
    process.exit(1);
  }

  // 1. Ensure Local Workspaces Exist
  await mkdir(INPUT_DIR, { recursive: true });
  await mkdir(OUTPUT_DIR, { recursive: true });

  // 2. Wait for ComfyUI to respond on port 8188
  await wait_for_comfy_ready();

  let empty_poll_count = 0;
  console.log(`[Worker] Polling for '${MODEL_TYPE}' jobs every ${POLL_INTERVAL_SECONDS}s...`);

  while (true) {
    try {
      const result = await poll_for_job();

      if (!result || !result.success || !result.data) {
        empty_poll_count++;
        if (empty_poll_count % 5 === 0 || empty_poll_count === 1) {
          console.log(`[Worker] No jobs in queue (${empty_poll_count}/${MAX_EMPTY_POLLS})`);
        }

        if (empty_poll_count >= MAX_EMPTY_POLLS) {
          await handle_inactivity_shutdown();
        }

        await sleep(POLL_INTERVAL_SECONDS * 1000);
        continue;
      }

      empty_poll_count = 0;
      await process_job(result.data);
      // Zero sleep on success path: loops immediately to poll next job

    } catch (err) {
      console.error('[Worker] Fatal error in main worker loop:', err.message);
      await sleep(POLL_INTERVAL_SECONDS * 1000);
    }
  }
};

const handle_exit = async () => {
  console.log('[Worker] Termination signal received.');
  await flush_pending_uploads();
  process.exit(0);
};

process.on('SIGINT', handle_exit);
process.on('SIGTERM', handle_exit);

worker_loop().catch((err) => {
  console.error('[Worker] Uncaught exception:', err);
  process.exit(1);
});
