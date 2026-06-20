// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { AtsurProvenance } from "../AtsurProvenance.sol";

/**
 * @title MockProvenanceV2
 * @dev Test-only upgrade target — exists solely to prove storage continuity across a real
 *      UUPS upgrade in test/UpgradeFlow.test.js. Inherits AtsurProvenance's entire storage
 *      layout (including its __gap) and appends one new field after it. This is the safe,
 *      standard way to extend storage on upgrade: every existing slot keeps its position, and
 *      the new field lands in previously-reserved/unused space rather than shifting anything.
 */
contract MockProvenanceV2 is AtsurProvenance {
    uint256 public newField;

    function setNewField(uint256 value) external {
        newField = value;
    }
}
