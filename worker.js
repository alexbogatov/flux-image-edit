import os from 'os';
import { readFileSync, createReadStream, existsSync } from 'fs';
import { mkdir, writeFile, stat, unlink } from 'fs/promises';
import { join } from 'path';
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';

// ============================================
// CONSTANTS & IDENTITY
// ============================================
const COMFY_PORT = 8188;
const COMFY_HOST = `http://127.0.0.1:${COMFY_PORT}`;
const WORKFLOW_PATH = join(process.cwd(), 'video_ltx2_5_i2v.json');

const BASE_COMFY_DIR = existsSync('/app/ComfyUI') ? '/app/ComfyUI' : join(process.cwd(), 'ComfyUI');
const INPUT_DIR = join(BASE_COMFY_DIR, 'input');
const OUTPUT_DIR = join(BASE_COMFY_DIR, 'output');

// Identity strictly derived from the OS Hostname
const MACHINE_ID = os.hostname();
let WORKER_SECRET = null;
let HYPERSTACK_VM_ID = null;

// API Configuration
const API_BASE_URL = process.env.API_BASE_URL || 'https://api.runltx.com';
const POLL_INTERVAL_SECONDS = parseInt(process.env.POLL_INTERVAL_SECONDS) || 1;
const MAX_EMPTY_POLLS = 3;
const MAX_RETRY_COUNT = 2;

// Hyperstack Configuration
const HYPERSTACK_API_URL = process.env.HYPERSTACK_API_URL || 'https://infrahub-api.nexgencloud.com/v1';
const HYPERSTACK_API_KEY = process.env.HYPERSTACK_API_KEY;

// R2 Configuration
const R2_ACCOUNT_ID = process.env.R2_ACCOUNT_ID;
const R2_ACCESS_KEY_ID = process.env.R2_ACCESS_KEY_ID;
const R2_SECRET_ACCESS_KEY = process.env.R2_SECRET_ACCESS_KEY;
const R2_BUCKET_NAME = process.env.R2_BUCKET_NAME;
const R2_CDN_URL = process.env.R2_CDN_URL;

console.log('====================================================');
console.log(`[Config] Machine ID:       ${MACHINE_ID}`);
console.log(`[Config] API Endpoint:     ${API_BASE_URL}`);
console.log(`[Config] Comfy Host:       ${COMFY_HOST}`);
console.log(`[Config] Comfy Output Dir: ${OUTPUT_DIR}`);
console.log(`[Config] R2 Account ID:    ${R2_ACCOUNT_ID ? 'Configured (' + R2_ACCOUNT_ID.slice(0, 6) + '...)' : 'MISSING'}`);
console.log(`[Config] R2 Bucket:        ${R2_BUCKET_NAME || 'MISSING'}`);
console.log(`[Config] R2 CDN URL:       ${R2_CDN_URL || 'MISSING'}`);
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

const get_api_headers = () => ({
    'worker-auth': WORKER_SECRET,
    'content-type': 'application/json'
});

const get_hyperstack_headers = () => ({
    'api_key': HYPERSTACK_API_KEY,
    'content-type': 'application/json'
});

// ============================================
// Dynamic Registration & Cloud Discovery
// ============================================
const register_with_api = async () => {
    console.log(`[Worker Init] Registering hostname '${MACHINE_ID}' with central API...`);

    while (!WORKER_SECRET) {
        try {
            const res = await fetch(`${API_BASE_URL}/v1/worker/register`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ MACHINE_ID })
            });

            const text = await res.text();
            let data;
            try {
                data = JSON.parse(text);
            } catch (_) {
                data = { raw: text };
            }

            if (res.ok && data.STATUS === 'OK' && data.SECRET) {
                WORKER_SECRET = data.SECRET;
                console.log(`[Worker Init] Host '${MACHINE_ID}' authorized. Secret token established.`);
                return WORKER_SECRET;
            }

            console.error(`[Worker Init] Registration rejected (HTTP ${res.status}):`, JSON.stringify(data));
            console.log('[Worker Init] Retrying in 5 seconds...');
        } catch (err) {
            console.error(`[Worker Init] Connection error: ${err.message}. Retrying in 5s...`);
        }
        await sleep(5000);
    }
};

const resolve_hyperstack_vm_id = async () => {
    if (HYPERSTACK_VM_ID) return HYPERSTACK_VM_ID;
    if (!HYPERSTACK_API_KEY) {
        console.warn('[Hyperstack] HYPERSTACK_API_KEY missing. Skipping VM discovery.');
        return null;
    }

    try {
        console.log(`[Hyperstack] Querying VM ID for hostname '${MACHINE_ID}'...`);
        const res = await fetch(`${HYPERSTACK_API_URL}/core/virtual-machines`, {
            method: 'GET',
            headers: get_hyperstack_headers()
        });

        if (!res.ok) {
            const err_text = await res.text();
            throw new Error(`HTTP ${res.status}: ${err_text}`);
        }

        const data = await res.json();
        const instances = data.instances || [];
        const match = instances.find((vm) => vm.name.toLowerCase() === MACHINE_ID.toLowerCase());

        if (!match) {
            console.warn(`[Hyperstack] VM '${MACHINE_ID}' not found in active instances list.`);
            return null;
        }

        HYPERSTACK_VM_ID = match.id;
        console.log(`[Hyperstack] Discovered VM ID: ${HYPERSTACK_VM_ID} (Name: ${match.name})`);
        return HYPERSTACK_VM_ID;
    } catch (err) {
        console.error('[Hyperstack Discovery Error]:', err.message);
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

// ============================================
// Central Backend API Handshakes
// ============================================
const poll_for_job = async (job_type, model) => {
    try {
        const url = `${API_BASE_URL}/v1/worker/get?job_type=${job_type}&model=${model}`;
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
    console.log(`[API Handshake] Submitting completion for job '${job_id}'...`);
    console.log(`[API Handshake] Output URL: ${output_url} | Time: ${generation_time_sec.toFixed(2)}s`);

    const response = await fetch(`${API_BASE_URL}/v1/worker/complete`, {
        method: 'POST',
        headers: get_api_headers(),
        body: JSON.stringify({ job_id, output_url, generation_time_sec })
    });

    if (!response.ok) {
        const err_text = await response.text();
        throw new Error(`API complete error: HTTP ${response.status} - ${err_text}`);
    }
    const result = await response.json();
    console.log(`[API Handshake] Job '${job_id}' marked completed on server:`, JSON.stringify(result));
    return result;
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
        await sleep(2000);
    }
};

const optimize_and_configure_workflow = (workflow, job_params) => {
    const { image_filename, prompt_text, duration_sec, fps = 25 } = job_params;

    for (const [node_id, node] of Object.entries(workflow)) {
        if (!node || !node.inputs) continue;

        // 1. Duration & FPS
        if (node.class_type === 'PrimitiveInt') {
            const title = node._meta?.title?.toLowerCase() || '';
            if (title === 'duration' && duration_sec) {
                node.inputs.value = Number(duration_sec);
            } else if (title === 'frame rate' && fps) {
                node.inputs.value = Number(fps);
            }
        }

        // 2. Random Seeds
        if (node.class_type === 'RandomNoise') {
            node.inputs.noise_seed = Math.floor(Math.random() * 1000000000000000);
        }

        // 3. Load First Frame Image
        if (node.class_type === 'LoadImage' && image_filename) {
            node.inputs.image = image_filename;
        }

        // 4. Positive vs Negative Prompts
        if (node.class_type === 'CLIPTextEncode') {
            const title = node._meta?.title?.toLowerCase() || '';
            if (title.includes('negative')) {
                node.inputs.text = ''; // Zero-out negative prompt for distilled 1.0 CFG passes
            } else if (prompt_text) {
                node.inputs.text = prompt_text;
            }
        }

        // Also check multiline prompt input primitive
        if (node.class_type === 'PrimitiveStringMultiline' && prompt_text) {
            node.inputs.value = prompt_text;
        }

        // 5. Optimize Tiled VAE for A100 (80GB VRAM allows tile_size 1024)
        if (node.class_type === 'VAEDecodeTiled') {
            node.inputs.tile_size = 1024;
            node.inputs.overlap = 64;
            node.inputs.temporal_size = 4096;
            node.inputs.temporal_overlap = 32;
        }
    }

    return workflow;
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
    console.log(`[ComfyUI] Job '${job_id}' accepted. Prompt ID: ${prompt_id}`);
    const start_time = Date.now();

    while (true) {
        await sleep(1500);
        const history_res = await fetch(`${COMFY_HOST}/history/${prompt_id}`);
        if (history_res.ok) {
            const history_data = await history_res.json();
            const job_history = history_data[prompt_id];

            if (job_history) {
                const duration = (Date.now() - start_time) / 1000;

                // Check for execution errors
                if (job_history.status?.status_str === 'error') {
                    const messages = job_history.status.messages || [];
                    throw new Error(`ComfyUI execution error: ${JSON.stringify(messages)}`);
                }

                // Extract output video directly from SaveVideo or CreateVideo outputs
                const outputs = job_history.outputs || {};
                for (const nodeId in outputs) {
                    const nodeOutput = outputs[nodeId];
                    const mediaList = nodeOutput.videos || nodeOutput.images || nodeOutput.gifs || [];
                    if (mediaList.length > 0) {
                        const media = mediaList[0];
                        const subfolder = media.subfolder ? `${media.subfolder}/` : '';
                        const output_path = join(OUTPUT_DIR, `${subfolder}${media.filename}`);

                        console.log(`[ComfyUI] Execution successful in ${duration.toFixed(2)}s.`);
                        console.log(`[ComfyUI] Resolved output path: ${output_path}`);
                        return { output_path, duration };
                    }
                }

                throw new Error(`ComfyUI finished prompt ${prompt_id} but output node produced no video references.`);
            }
        }
    }
};

// ============================================
// Image & Video IO
// ============================================
const download_image = async (url, filename) => {
    console.log(`[Input IO] Downloading input image: ${url}`);
    const res = await fetch(url);
    if (!res.ok) throw new Error(`Input download failed: HTTP ${res.status} (${res.statusText})`);

    const buffer = await res.arrayBuffer();
    await mkdir(INPUT_DIR, { recursive: true });
    const image_path = join(INPUT_DIR, filename);
    await writeFile(image_path, Buffer.from(buffer));

    const stats = await stat(image_path);
    console.log(`[Input IO] Input image saved: ${image_path} (${(stats.size / 1024).toFixed(1)} KB)`);
    return image_path;
};

const upload_to_r2 = async (file_path, job_id) => {
    if (!existsSync(file_path)) {
        throw new Error(`File not found for R2 upload at path: ${file_path}`);
    }

    const file_stats = await stat(file_path);
    const key = `generations/${job_id}.mp4`;
    const file_stream = createReadStream(file_path);

    console.log(`[R2 Upload] Starting upload for job '${job_id}'...`);
    console.log(`[R2 Upload] Local File:  ${file_path} (${(file_stats.size / 1024 / 1024).toFixed(2)} MB)`);
    console.log(`[R2 Upload] Bucket:      ${R2_BUCKET_NAME}`);
    console.log(`[R2 Upload] Key:         ${key}`);

    const result = await s3_client.send(new PutObjectCommand({
        Bucket: R2_BUCKET_NAME,
        Key: key,
        Body: file_stream,
        ContentType: 'video/mp4',
    }));

    const httpStatus = result.$metadata?.httpStatusCode;
    console.log(`[R2 Upload] S3 PutObject finished with HTTP status: ${httpStatus}`);

    if (httpStatus && httpStatus !== 200 && httpStatus !== 204) {
        throw new Error(`R2 upload returned non-success HTTP status: ${httpStatus}`);
    }

    const public_url = `${R2_CDN_URL}/${key}`;
    console.log(`[R2 Upload] Public CDN destination URL: ${public_url}`);
    return public_url;
};

const cleanup_job_files = async (input_path, output_path) => {
    console.log('[Cleanup] Removing temporary job artifacts from disk...');
    if (input_path) {
        try {
            await unlink(input_path);
            console.log(`[Cleanup] Deleted input:  ${input_path}`);
        } catch (e) {
            console.warn(`[Cleanup Warning] Could not remove input file: ${e.message}`);
        }
    }
    if (output_path) {
        try {
            await unlink(output_path);
            console.log(`[Cleanup] Deleted output: ${output_path}`);
        } catch (e) {
            console.warn(`[Cleanup Warning] Could not remove output file: ${e.message}`);
        }
    }
};

// ============================================
// Main Job Processing Loop
// ============================================
const process_job = async (job_data) => {
    const { job_id, image_url, duration_sec, prompt, job_type, model } = job_data;
    let retry_count = 0;
    let input_path = null;
    let output_path = null;

    console.log(`\n====================================================`);
    console.log(`[Job ${job_id}] Processing (${job_type || 'generate'}/${model || 'ltx-i2v'}) - Duration: ${duration_sec || 2}s`);
    console.log(`[Job ${job_id}] Prompt: ${format_prompt_preview(prompt)}`);
    console.log(`====================================================`);

    while (retry_count < MAX_RETRY_COUNT) {
        try {
            const input_filename = `${job_id}_input.jpg`;
            input_path = await download_image(image_url, input_filename);

            const raw_workflow = readFileSync(WORKFLOW_PATH, 'utf-8');
            let workflow = JSON.parse(raw_workflow);

            // Apply all dynamic modifications without touching the static JSON file
            workflow = optimize_and_configure_workflow(workflow, {
                image_filename: input_filename,
                prompt_text: prompt,
                duration_sec: duration_sec || 2,
                fps: 25
            });

            console.log(`[Job ${job_id}] Configured workflow graph (VAE Tile Size: 1024, Negative: Empty)`);

            // Execute inside ComfyUI
            const { output_path: generated_file, duration } = await execute_workflow(workflow, job_id);
            output_path = generated_file;

            // Stream upload to Cloudflare R2
            const r2_url = await upload_to_r2(output_path, job_id);

            // Handshake back to orchestrator API
            await complete_job(job_id, r2_url, duration);

            // Cleanup local artifacts
            await cleanup_job_files(input_path, output_path);

            console.log(`[Job ${job_id}] Processing cycle complete in ${duration.toFixed(2)}s\n`);
            return true;
        } catch (err) {
            retry_count++;
            console.error(`[Job ${job_id}] Attempt ${retry_count}/${MAX_RETRY_COUNT} failed with error:`);
            console.error(err.stack || err.message);

            if (retry_count >= MAX_RETRY_COUNT) {
                console.error(`[Job ${job_id}] Max retries reached. Reporting failure to server...`);
                try { await fail_job(job_id, err.message); } catch (_) {}
                await cleanup_job_files(input_path, output_path);
                return false;
            }
            console.log(`[Job ${job_id}] Waiting ${retry_count * 3}s before retry...`);
            await sleep(retry_count * 3000);
        }
    }
    return false;
};

const worker_loop = async () => {
    console.log(`[Worker] Daemon started on machine: ${MACHINE_ID}`);

    // 1. Handshake with Central API
    await register_with_api();

    // 2. Discover Hyperstack VM ID for Hibernate Control
    await resolve_hyperstack_vm_id();

    // 3. Ensure Local Workspaces Exist
    await mkdir(INPUT_DIR, { recursive: true });
    await mkdir(OUTPUT_DIR, { recursive: true });

    // 4. Wait for ComfyUI to respond on port 8188
    await wait_for_comfy_ready();

    let empty_poll_count = 0;
    const job_type = process.env.JOB_TYPE || 'generate';
    const model = process.env.MODEL || 'ltx-i2v';

    console.log(`[Worker] Polling for '${model}' jobs every ${POLL_INTERVAL_SECONDS}s...`);

    while (true) {
        try {
            const result = await poll_for_job(job_type, model);

            if (!result || !result.success || !result.data) {
                empty_poll_count++;
                if (empty_poll_count % 5 === 0 || empty_poll_count === 1) {
                    console.log(`[Worker] No jobs in queue (${empty_poll_count}/${MAX_EMPTY_POLLS})`);
                }

                if (empty_poll_count >= MAX_EMPTY_POLLS) {
                    console.log('[Worker] Inactivity threshold reached. Initiating VM hibernation...');
                    await hibernate_vm();
                    process.exit(0);
                }

                await sleep(POLL_INTERVAL_SECONDS * 1000);
                continue;
            }

            empty_poll_count = 0;
            await process_job(result.data);
            await sleep(1000);
        } catch (err) {
            console.error('[Worker] Fatal error in main worker loop:', err.message);
            await sleep(POLL_INTERVAL_SECONDS * 1000);
        }
    }
};

process.on('SIGINT', () => {
    console.log('[Worker] SIGINT received. Shutting down...');
    process.exit(0);
});

process.on('SIGTERM', () => {
    console.log('[Worker] SIGTERM received. Shutting down...');
    process.exit(0);
});

worker_loop().catch((err) => {
    console.error('[Worker] Uncaught exception:', err);
    process.exit(1);
});
