#!/usr/bin/env node
const { MerkleTree } = require("merkletreejs");
const keccak256 = require("keccak256");

// Read input from stdin
const input = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
const leaves = input.leaves;

// Convert leaves to Buffers
const leafBuffers = leaves.map(leaf => {
    if (typeof leaf === 'string') {
        // If it's a hex string, convert it
        if (leaf.startsWith('0x')) {
            return Buffer.from(leaf.slice(2), 'hex');
        }
        // Otherwise hash it
        return keccak256(leaf);
    }
    return Buffer.from(leaf.slice(2), 'hex');
});

// Create Merkle tree with sortPairs: true to match OpenZeppelin
const tree = new MerkleTree(leafBuffers, keccak256, {
    sortPairs: true,
    hashLeaves: false
});

const root = '0x' + tree.getRoot().toString('hex');
const proofs = leafBuffers.map(leaf => {
    const proof = tree.getProof(leaf);
    return proof.map(p => '0x' + p.data.toString('hex'));
});

// Output JSON
console.log(JSON.stringify({
    root,
    proofs,
    leaves: leafBuffers.map(leaf => '0x' + leaf.toString('hex'))
}));

