/**
 * syncDeployment.js — Save a deployment manifest and mirror it to registry-cloud/.deployments/.
 *
 * Called at the end of every deploy script so registry-cloud always has the
 * latest contract addresses without manual copying.
 *
 * @param {object} manifest  - The deployment object to write.
 * @param {string} filename  - File name, e.g. "31337.json" or "4202.json".
 */

const fs   = require("fs");
const path = require("path");

/**
 * @param {object} manifest
 * @param {string} filename  e.g. "4202.json"
 */
function syncDeployment(manifest, filename) {
    // 1. Save to provenance-onchain/.deployments/<filename>
    const onchainDir = path.join(__dirname, "..", ".deployments");
    fs.mkdirSync(onchainDir, { recursive: true });
    const onchainPath = path.join(onchainDir, filename);
    fs.writeFileSync(onchainPath, JSON.stringify(manifest, null, 2));
    console.log(`  ✓ manifest → ${path.relative(process.cwd(), onchainPath)}`);

    // 2. Mirror to registry-cloud/.deployments/<filename> (best-effort)
    const cloudDir = path.join(__dirname, "..", "..", "registry-cloud", ".deployments");
    if (!fs.existsSync(cloudDir)) {
        // Try one level up in case monorepo root differs
        const altCloudDir = path.join(__dirname, "..", "..", "..", "registry-cloud", "deployments");
        if (fs.existsSync(altCloudDir)) {
            writeCloud(manifest, filename, altCloudDir);
        } else {
            console.warn(`  ⚠ registry-cloud/deployments not found — skipping mirror. Create it or run from the registry-cluster root.`);
        }
        return;
    }
    writeCloud(manifest, filename, cloudDir);
}

function writeCloud(manifest, filename, cloudDir) {
    const cloudPath = path.join(cloudDir, filename);
    fs.writeFileSync(cloudPath, JSON.stringify(manifest, null, 2));
    console.log(`  ✓ manifest → ${path.relative(process.cwd(), cloudPath)} (registry-cloud mirror)`);
}

module.exports = { syncDeployment };
