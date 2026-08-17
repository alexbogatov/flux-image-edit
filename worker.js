import os from 'os';
import { readFileSync, createReadStream } from 'fs';
import { mkdir, writeFile, readdir, stat, unlink } from 'fs/promises';
import { join } from 'path';
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';

// ============================================
// CONSTANTS & IDENTITY
// ============================================
const COMFY_PORT = 8188;
const COMFY_HOST = `http://127.0.0.1:${COMFY_PORT}`;
const WORKFLOW_PATH = join(process.cwd(), 'flux.2.klein.json');
const INPUT_DIR = join(process.cwd(), 'ComfyUI', 'input');
const OUTPUT_DIR = join(process.cwd(), 'ComfyUI', 'output');

// Identity from Salad instance environment or machine hostname
const MACHINE_ID = process.env.SALAD_MACHINE_ID || process.env.SALAD_CONTAINER_GROUP_INSTANCE_ID || os.hostname();

// Central Backend Configuration (Hardcoded)
const API_BASE_URL = 'https://api.runltx.com';
const JOB_TYPE = 'generate';
const MODEL_TYPE = 'image-edit';
const POLL_INTERVAL_SECONDS = 3;
const MAX_RETRY_COUNT = 2;
const MAX_EMPTY_POLLS = 10; // 10 polls * 3s = 30 seconds of inactivity before shutdown

let WORKER_SECRET = null;

// ============================================
// Salad Cloud Configuration (Auto-Shutdown)
// ============================================
const SALAD_API_URL = 'https://api.salad.com/api/public';
const SALAD_API_KEY = process.env.SALAD_API_KEY;
const SALAD_ORG_NAME = process.env.SALAD_ORG_NAME;
const SALAD_PROJECT_NAME = process.env.SALAD_PROJECT_NAME;
const SALAD_CONTAINER_GROUP_NAME = process.env.SALAD_CONTAINER_GROUP_NAME || 'flux-image-edit-worker';

// ============================================
// R2 Storage Client
// ============================================
const R2_ACCOUNT_ID = process.env.R2_ACCOUNT_ID;
const R2_ACCESS_KEY_ID = process.env.R2_ACCESS_KEY_ID;
const R2_SECRET_ACCESS_KEY = process.env.R2_SECRET_ACCESS_KEY;
const R2_BUCKET_NAME = process.env.R2_BUCKET_NAME;
const R2_CDN_URL = process.env.R2_CDN_URL;

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

const get_api_headers = () => ({
    'worker-auth': WORKER_SECRET,
    'content-type': 'application/json'
});

const stop_salad_container_group = async () => {
    if (!SALAD_API_KEY || !SALAD_ORG_NAME || !SALAD_PROJECT_NAME) {
        console.warn('[Shutdown] Salad credentials missing in environment. Cannot scale down via API.');
        return false;
    }

    try {
        console.log(`[Shutdown] Inactivity threshold reached. Scaling container group '${SALAD_CONTAINER_GROUP_NAME}' to 0 replicas...`);
        const url = `${SALAD_API_URL}/organizations/${SALAD_ORG_NAME}/projects/${SALAD_PROJECT_NAME}/containers/${SALAD_CONTAINER_GROUP_NAME}`;
        
        const res = await fetch(url, {
            method: 'PATCH',
            headers: {
                'Salad-Api-Key': SALAD_API_KEY,
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ replicas: 0 })
        });

        if (!res.ok) {
            const err_text = await res.text();
            throw new Error(`Salad scale-down error HTTP ${res.status}: ${err_text}`);
        }

        console.log('[Shutdown] Successfully scaled container group to 0 replicas.');
        return true;
    } catch (err) {
        console.error('[Shutdown Error]:', err.message);
        return false;
    }
};

// ============================================
// Central Backend API Handshakes
// ============================================
const register_with_api = async () => {
    console.log(`[Worker Init] Registering '${MACHINE_ID}' for model '${MODEL_TYPE}'...`);

    while (!WORKER_SECRET) {
        try {
            const res = await fetch(`${API_BASE_URL}/v1/worker/register`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ 
                    MACHINE_ID, 
                    model_type: MODEL_TYPE 
                })
            });

            const data = await res.json();

            if (res.ok && data.STATUS === 'OK' && data.SECRET) {
                WORKER_SECRET = data.SECRET;
                console.log(`[Worker Init] Worker authorized. Token established.`);
                return WORKER_SECRET;
            }

            console.error(`[Worker Init] Registration rejected:`, JSON.stringify(data));
        } catch (err) {
            console.error(`[Worker Init] Connection error: ${err.message}. Retrying in 5s...`);
        }
        await sleep(5000);
    }
};

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
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`);
    return await response.json();
};

const fail_job = async (job_id, error_message) => {
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

const execute_workflow = async (workflow) => {
    const response = await fetch(`${COMFY_HOST}/prompt`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ prompt: workflow }),
    });

    if (!response.ok) {
        const err_text = await response.text();
        throw new Error(`ComfyUI prompt error: ${response.status} - ${err_text}`);
    }

    const { prompt_id } = await response.json();
    const start_time = Date.now();

    while (true) {
        await sleep(1000);
        const history_res = await fetch(`${COMFY_HOST}/history/${prompt_id}`);
        if (history_res.ok) {
            const history_data = await history_res.json();
            if (history_data[prompt_id]) {
                return (Date.now() - start_time) / 1000;
            }
        }
    }
};

// ============================================
// Image IO & Storage
// ============================================
const find_latest_image = async (dir) => {
    const files = [];
    const walk = async (current_dir) => {
        try {
            const entries = await readdir(current_dir, { withFileTypes: true });
            for (const entry of entries) {
                const full_path = join(current_dir, entry.name);
                if (entry.isDirectory()) {
                    await walk(full_path);
                } else if (/\.(png|jpg|jpeg|webp)$/i.test(entry.name)) {
                    const stats = await stat(full_path);
                    files.push({ path: full_path, mtime: stats.mtime });
                }
            }
        } catch (_) {}
    };

    await walk(dir);
    if (files.length === 0) return null;
    files.sort((a, b) => b.mtime.getTime() - a.mtime.getTime());
    return files[0].path;
};

const download_image = async (url, filename) => {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`Failed to download input image: ${res.statusText}`);
    const buffer = await res.arrayBuffer();
    await mkdir(INPUT_DIR, { recursive: true });
    const image_path = join(INPUT_DIR, filename);
    await writeFile(image_path, Buffer.from(buffer));
    return image_path;
};

const upload_to_r2 = async (file_path, job_id) => {
    const ext = file_path.endsWith('.png') ? 'png' : 'jpg';
    const key = `edits/${job_id}.${ext}`;
    const file_stream = createReadStream(file_path);

    await s3_client.send(new PutObjectCommand({
        Bucket: R2_BUCKET_NAME,
        Key: key,
        Body: file_stream,
        ContentType: ext === 'png' ? 'image/png' : 'image/jpeg',
    }));

    return `${R2_CDN_URL}/${key}`;
};

const cleanup_job_files = async (input_path, output_path) => {
    if (input_path) try { await unlink(input_path); } catch (_) {}
    if (output_path) try { await unlink(output_path); } catch (_) {}
};

// ============================================
// Main Job Processing Loop
// ============================================
const process_job = async (job_data) => {
    const { job_id, image_url, prompt } = job_data;
    let retry_count = 0;
    let input_path = null;
    let output_path = null;

    console.log(`[Job ${job_id}] Processing image edit job...`);

    while (retry_count < MAX_RETRY_COUNT) {
        try {
            const input_filename = `${job_id}_input.jpg`;
            input_path = await download_image(image_url, input_filename);

            const workflow = JSON.parse(readFileSync(WORKFLOW_PATH, 'utf-8'));

            // Map workflow inputs
            workflow["76"].inputs.image = input_filename;
            workflow["75:73"].inputs.noise_seed = Math.floor(Math.random() * 1000000000000000);
            if (prompt) {
                workflow["75:74"].inputs.text = prompt;
            }

            const generation_time = await execute_workflow(workflow);
            output_path = await find_latest_image(OUTPUT_DIR);

            if (!output_path) {
                throw new Error('ComfyUI finished execution but output image was not found.');
            }

            const r2_url = await upload_to_r2(output_path, job_id);
            await complete_job(job_id, r2_url, generation_time);
            await cleanup_job_files(input_path, output_path);

            console.log(`[Job ${job_id}] Finished successfully in ${generation_time.toFixed(2)}s`);
            return true;
        } catch (err) {
            retry_count++;
            console.error(`[Job ${job_id}] Attempt ${retry_count} failed: ${err.message}`);

            if (retry_count >= MAX_RETRY_COUNT) {
                try { await fail_job(job_id, err.message); } catch (_) {}
                await cleanup_job_files(input_path, output_path);
                return false;
            }
            await sleep(retry_count * 3000);
        }
    }
    return false;
};

const worker_loop = async () => {
    console.log(`[Worker] Started on host: ${MACHINE_ID}`);

    await register_with_api();
    await mkdir(INPUT_DIR, { recursive: true });
    await mkdir(OUTPUT_DIR, { recursive: true });
    await wait_for_comfy_ready();

    let empty_poll_count = 0;
    console.log(`[Worker] Polling for '${MODEL_TYPE}' jobs every ${POLL_INTERVAL_SECONDS}s...`);

    while (true) {
        try {
            const result = await poll_for_job();

            if (!result || !result.success || !result.data) {
                empty_poll_count++;
                console.log(`[Worker] No jobs available (${empty_poll_count}/${MAX_EMPTY_POLLS})`);

                if (empty_poll_count >= MAX_EMPTY_POLLS) {
                    console.log('[Worker] Idle threshold reached. Initiating Salad container shutdown...');
                    await stop_salad_container_group();
                    process.exit(0);
                }

                await sleep(POLL_INTERVAL_SECONDS * 1000);
                continue;
            }

            // Reset counter when a job is received
            empty_poll_count = 0;
            await process_job(result.data);
            await sleep(1000);
        } catch (err) {
            console.error('[Worker] Loop error:', err.message);
            await sleep(POLL_INTERVAL_SECONDS * 1000);
        }
    }
};

process.on('SIGINT', () => process.exit(0));
process.on('SIGTERM', () => process.exit(0));

worker_loop().catch((err) => {
    console.error('[Worker] Fatal error:', err);
    process.exit(1);
});
