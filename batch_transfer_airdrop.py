#!/usr/bin/env python3
"""
Tool used by BattleDoge to batch ERC-20 transfers.
Features per-transfer pause and receipt status.

PATCHED VERSION - Improvements:
- Dry-run mode for simulation
- CSV audit log of all transfers
- Proper success/failure tracking
- Fixed receipt undefined bug
- Resume from failed transfer support

- PRIVATE_KEY is a placeholder (replace before running).
- Hardcoded recipients list (address, amount_without_decimals).
- Converts amounts to token units using token decimals (expects 18, and will abort if not 18).
- Sends one transfer at a time, waits for receipt, prints status, then pauses.
"""

from __future__ import annotations

import csv
import os
import sys
from datetime import datetime, timezone
from decimal import Decimal
from typing import List, Tuple, Optional

from web3 import Web3
from web3.exceptions import ContractLogicError, TimeExhausted

# --------------------
# CONFIG (edit these)
# --------------------

RPC_URL = os.environ.get("RPC_URL") or "https://rpc.mevblocker.io" # At BattleDoge, we always recommend using mevblocker.io instead of the regular ETH Mainnet RPCs
PRIVATE_KEY = "0xPrivateKey"  # <<< REPLACE ME
TOKEN_ADDRESS = Web3.to_checksum_address("0x2C724d1FcA1B3D471EBAa004a054621aF85D417C") # BDOGE Token Address

EXPECTED_DECIMALS = 18  # Enforced to avoid silent mis-sends.

RECEIPT_TIMEOUT_SECONDS = 300
RECEIPT_POLL_LATENCY_SECONDS = 2

# EIP-1559 tuning
MAX_PRIORITY_FEE_GWEI = None         # e.g. 1.5
MAX_FEE_MULTIPLIER = Decimal("2.0")  # maxFeePerGas ≈ baseFee * MULTIPLIER + priority

# ------------------------------
# NEW: Safety & Logging Options
# ------------------------------
DRY_RUN = True  # <<< Needs to be SET TO False FOR REAL TRANSACTIONS
LOG_FILE = "transfer_audit_log.csv"  # Audit trail
SKIP_FIRST_N = 0  # Resume: skip first N recipients (use if resuming after failure)

# -------------------
# Minimal ERC-20 ABI
# -------------------
ERC20_ABI = [
    {"name": "name", "type": "function", "stateMutability": "view", "inputs": [], "outputs": [{"type": "string"}]},
    {"name": "symbol", "type": "function", "stateMutability": "view", "inputs": [], "outputs": [{"type": "string"}]},
    {"name": "decimals", "type": "function", "stateMutability": "view", "inputs": [], "outputs": [{"type": "uint8"}]},
    {"name": "balanceOf", "type": "function", "stateMutability": "view", "inputs": [{"name": "a", "type": "address"}], "outputs": [{"type": "uint256"}]},
    {"name": "transfer", "type": "function", "stateMutability": "nonpayable",
     "inputs": [{"name": "to", "type": "address"}, {"name": "amount", "type": "uint256"}],
     "outputs": [{"type": "bool"}]},
    {"anonymous": False, "type": "event", "name": "Transfer",
     "inputs": [
         {"indexed": True, "name": "from", "type": "address"},
         {"indexed": True, "name": "to", "type": "address"},
         {"indexed": False, "name": "value", "type": "uint256"},
     ]},
]

# ---------------------------------------------------------------
# Recipient list: "address, amount" (amount WITHOUT 18 decimals)
# ---------------------------------------------------------------
RECIPIENTS_RAW = r"""
0x000000000000000000000000000000000000dead, 1000
0x000000000000000000000000000000000000dead, 2000
""".strip()


# -------------
# Audit Logger
# -------------
class AuditLogger:
    def __init__(self, filepath: str):
        self.filepath = filepath
        self.file = None
        self.writer = None

    def __enter__(self):
        file_exists = os.path.exists(self.filepath)
        self.file = open(self.filepath, "a", newline="", encoding="utf-8")
        self.writer = csv.writer(self.file)
        if not file_exists:
            self.writer.writerow([
                "timestamp", "transfer_num", "to_address", "amount_human",
                "amount_raw", "tx_hash", "status", "block_number", "gas_used", "error"
            ])
        return self

    def __exit__(self, *args):
        if self.file:
            self.file.close()

    def log(self, transfer_num: int, to_addr: str, amt_human: int, amt_raw: int,
            tx_hash: Optional[str], status: str, block: Optional[int],
            gas_used: Optional[int], error: Optional[str]):
        self.writer.writerow([
            datetime.now(timezone.utc).isoformat(),
            transfer_num,
            to_addr,
            amt_human,
            amt_raw,
            tx_hash or "",
            status,
            block or "",
            gas_used or "",
            error or ""
        ])
        self.file.flush()


def parse_recipients(raw: str) -> List[Tuple[str, int]]:
    out: List[Tuple[str, int]] = []
    for idx, line in enumerate(raw.splitlines(), start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "," not in line:
            raise ValueError(f"Line {idx} malformed (missing comma): {line!r}")

        addr_str, amt_str = [p.strip() for p in line.split(",", 1)]

        # Robust checksum conversion:
        try:
            addr = Web3.to_checksum_address(addr_str)
        except Exception:
            addr = Web3.to_checksum_address(addr_str.lower())

        amt = int(amt_str)
        if amt <= 0:
            raise ValueError(f"Line {idx} amount must be > 0, got {amt}")

        out.append((addr, amt))
    return out


def token_units(amount_no_decimals: int, decimals: int) -> int:
    return amount_no_decimals * (10 ** decimals)


def fmt_ether(w3: Web3, wei: int) -> str:
    return f"{w3.from_wei(wei, 'ether'):.6f} ETH"


def is_eip1559(w3: Web3) -> bool:
    latest = w3.eth.get_block("latest")
    return "baseFeePerGas" in latest and latest["baseFeePerGas"] is not None


def pick_fees(w3: Web3) -> dict:
    if is_eip1559(w3):
        latest = w3.eth.get_block("latest")
        base = int(latest["baseFeePerGas"])

        if MAX_PRIORITY_FEE_GWEI is None:
            priority = w3.to_wei(Decimal("1.5"), "gwei")
        else:
            priority = w3.to_wei(Decimal(str(MAX_PRIORITY_FEE_GWEI)), "gwei")

        max_fee = int(Decimal(base) * MAX_FEE_MULTIPLIER) + int(priority)
        return {"type": 2, "maxFeePerGas": int(max_fee), "maxPriorityFeePerGas": int(priority)}
    else:
        return {"gasPrice": int(w3.eth.gas_price)}


def main() -> int:
    if not RPC_URL or "YOUR_RPC_ENDPOINT" in RPC_URL:
        print("ERROR: Set RPC_URL (or export RPC_URL env var).", file=sys.stderr)
        return 1
    if not PRIVATE_KEY or "YOUR_PRIVATE_KEY_HERE" in PRIVATE_KEY:
        print("ERROR: Replace PRIVATE_KEY placeholder before running.", file=sys.stderr)
        return 1

    w3 = Web3(Web3.HTTPProvider(RPC_URL, request_kwargs={"timeout": 60}))
    if not w3.is_connected():
        print("ERROR: Could not connect to RPC.", file=sys.stderr)
        return 1

    acct = w3.eth.account.from_key(PRIVATE_KEY)
    sender = acct.address

    token = w3.eth.contract(address=TOKEN_ADDRESS, abi=ERC20_ABI)

    # Metadata
    try:
        name = token.functions.name().call()
    except Exception:
        name = "(name() unavailable)"
    try:
        symbol = token.functions.symbol().call()
    except Exception:
        symbol = "(symbol() unavailable)"

    try:
        decimals = int(token.functions.decimals().call())
    except Exception as e:
        print(f"ERROR: token.decimals() call failed: {e}", file=sys.stderr)
        return 1

    if decimals != EXPECTED_DECIMALS:
        print(f"ERROR: Token decimals is {decimals}, expected {EXPECTED_DECIMALS}. Aborting to avoid wrong sends.",
              file=sys.stderr)
        return 1

    all_recipients = parse_recipients(RECIPIENTS_RAW)

    # Apply SKIP_FIRST_N for resuming
    if SKIP_FIRST_N > 0:
        print(f"⚠️  SKIPPING first {SKIP_FIRST_N} recipients (resume mode)")
        recipients = all_recipients[SKIP_FIRST_N:]
    else:
        recipients = all_recipients

    total = len(recipients)
    total_all = len(all_recipients)
    total_tokens = sum(a for _, a in recipients)

    chain_id = w3.eth.chain_id
    latest_block = w3.eth.block_number

    eth_balance = w3.eth.get_balance(sender)
    token_balance = token.functions.balanceOf(sender).call()

    print("=" * 50)
    print("  Batch ERC-20 Transfer Script (PATCHED)")
    print("=" * 50)

    if DRY_RUN:
        print("\n🔶 DRY-RUN MODE - NO TRANSACTIONS WILL BE SENT 🔶\n")

    print(f"RPC_URL:        {RPC_URL}")
    print(f"Chain ID:       {chain_id}")
    print(f"Latest block:   {latest_block}")
    print(f"Sender:         {sender}")
    print(f"Token:          {name} ({symbol})")
    print(f"Token address:  {TOKEN_ADDRESS}")
    print(f"Token decimals: {decimals}")
    print(f"Sender ETH:     {fmt_ether(w3, eth_balance)}")
    print(f"Sender token:   {Decimal(token_balance) / Decimal(10**decimals)} {symbol}")
    print(f"Recipients:     {total} (of {total_all} total, skipping {SKIP_FIRST_N})")
    print(f"Total to send:  {total_tokens} {symbol} (human units)")
    print(f"Log file:       {LOG_FILE}\n")

    required_units = sum(token_units(a, decimals) for _, a in recipients)
    if token_balance < required_units:
        short = Decimal(required_units - token_balance) / Decimal(10**decimals)
        print(f"ERROR: Insufficient token balance. Short by {short} {symbol}.", file=sys.stderr)
        return 1

    # Confirm before starting
    if not DRY_RUN:
        confirm = input("⚠️  LIVE MODE: Type 'SEND' to proceed with real transactions: ").strip()
        if confirm != "SEND":
            print("Aborted.")
            return 1

    # Pending nonce is safer
    nonce = w3.eth.get_transaction_count(sender, "pending")
    print(f"Starting nonce (pending): {nonce}\n")

    # Stats tracking
    succeeded = 0
    failed = 0
    skipped = 0

    with AuditLogger(LOG_FILE) as audit:
        for i, (to_addr, amt_human) in enumerate(recipients, start=1):
            actual_num = i + SKIP_FIRST_N  # Actual position in full list
            remaining_after = total - i
            amt_units = token_units(amt_human, decimals)

            print(f"--- Transfer {actual_num}/{total_all} ---")
            print(f"To:            {to_addr}")
            print(f"Amount:        {amt_human} {symbol}  (raw: {amt_units} units)")
            print(f"Nonce:         {nonce}")

            # Initialize per-transfer state
            sent_tx_hash: Optional[str] = None
            receipt = None
            error_msg: Optional[str] = None
            status = "PENDING"

            if DRY_RUN:
                print("[DRY-RUN] Would send transaction here")
                status = "DRY_RUN"
                audit.log(actual_num, to_addr, amt_human, amt_units, None, status, None, None, None)
                print(f"\n🔶 [DRY-RUN] Transfer #{actual_num} simulated. {remaining_after} remaining.\n")
                skipped += 1
                nonce += 1  # Simulate nonce increment
                continue

            try:
                fee_fields = pick_fees(w3)

                # Gas estimate (+buffer)
                try:
                    est_gas = token.functions.transfer(to_addr, amt_units).estimate_gas({"from": sender})
                    gas_limit = int(est_gas * 1.15)
                except Exception as ge:
                    print(f"WARNING: gas estimate failed ({ge}); using fallback gas limit 120000")
                    gas_limit = 120_000

                tx = token.functions.transfer(to_addr, amt_units).build_transaction({
                    "from": sender,
                    "nonce": nonce,
                    "chainId": chain_id,
                    "gas": gas_limit,
                    **fee_fields,
                })

                if "maxFeePerGas" in tx:
                    print("Fee model:     EIP-1559")
                    print(f"maxFeePerGas:  {w3.from_wei(tx['maxFeePerGas'], 'gwei'):.3f} gwei")
                    print(f"priorityFee:   {w3.from_wei(tx['maxPriorityFeePerGas'], 'gwei'):.3f} gwei")
                else:
                    print("Fee model:     Legacy")
                    print(f"gasPrice:      {w3.from_wei(tx['gasPrice'], 'gwei'):.3f} gwei")

                print(f"Gas limit:     {tx['gas']}")

                signed = w3.eth.account.sign_transaction(tx, private_key=PRIVATE_KEY)

                # web3.py version compatibility: rawTransaction vs raw_transaction
                raw = getattr(signed, "rawTransaction", None) or getattr(signed, "raw_transaction")
                tx_hash = w3.eth.send_raw_transaction(raw)
                sent_tx_hash = tx_hash.hex()

                print(f"Tx hash:       {sent_tx_hash}")
                print("Waiting for receipt...")

                receipt = w3.eth.wait_for_transaction_receipt(
                    tx_hash,
                    timeout=RECEIPT_TIMEOUT_SECONDS,
                    poll_latency=RECEIPT_POLL_LATENCY_SECONDS,
                )

                print(f"Receipt block: {receipt.blockNumber}")
                print(f"Gas used:      {receipt.gasUsed}")

                if receipt.status == 1:
                    status = "SUCCESS"
                    print(f"Status:        SUCCESS ✅")
                    succeeded += 1
                else:
                    status = "REVERTED"
                    print(f"Status:        REVERTED ❌")
                    failed += 1

                # Optional: decode Transfer event (best-effort)
                try:
                    logs = token.events.Transfer().process_receipt(receipt)
                    if logs:
                        ev = logs[0]["args"]
                        val = Decimal(int(ev["value"])) / Decimal(10**decimals)
                        print(f"Transfer evt:  {ev['from']} -> {ev['to']} : {val} {symbol}")
                except Exception:
                    pass

            except TimeExhausted:
                status = "TIMEOUT"
                error_msg = "Receipt timeout - tx may still be pending"
                print(f"WARNING: {error_msg}", file=sys.stderr)
                failed += 1
            except ContractLogicError as cle:
                status = "CONTRACT_ERROR"
                error_msg = str(cle)
                print(f"ERROR: Contract reverted: {cle}", file=sys.stderr)
                failed += 1
            except Exception as e:
                status = "ERROR"
                error_msg = str(e)
                print(f"ERROR: Exception while sending tx: {e}", file=sys.stderr)
                failed += 1

            # Log to CSV
            audit.log(
                actual_num,
                to_addr,
                amt_human,
                amt_units,
                sent_tx_hash,
                status,
                receipt.blockNumber if receipt else None,
                receipt.gasUsed if receipt else None,
                error_msg
            )

            # Nonce handling
            if sent_tx_hash is not None and status in ("SUCCESS", "REVERTED", "TIMEOUT"):
                # Transaction was broadcast (even if reverted, it consumed the nonce)
                nonce += 1
            else:
                # Refresh nonce if we never broadcast
                nonce = w3.eth.get_transaction_count(sender, "pending")

            # Clear status message
            if status == "SUCCESS":
                print(f"\n✅ Transfer #{actual_num} SUCCEEDED. {remaining_after} remaining.")
            elif status == "REVERTED":
                print(f"\n❌ Transfer #{actual_num} REVERTED on-chain. {remaining_after} remaining.")
            elif status == "TIMEOUT":
                print(f"\n⚠️  Transfer #{actual_num} TIMEOUT (may still confirm). {remaining_after} remaining.")
            else:
                print(f"\n❌ Transfer #{actual_num} FAILED ({status}). {remaining_after} remaining.")

            if remaining_after > 0:
                input("Press Enter to continue to next transfer...")
            print()

    # Console log summary
    print("=" * 50)
    print("  SUMMARY")
    print("=" * 50)
    print(f"Succeeded: {succeeded}")
    print(f"Failed:    {failed}")
    if DRY_RUN:
        print(f"Simulated: {skipped}")
    print(f"Audit log: {LOG_FILE}")
    print("\nDone.")

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
