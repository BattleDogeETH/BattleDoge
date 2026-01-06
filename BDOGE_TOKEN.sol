// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/*
    BattleDogeToken.sol (single file, no imports)

    Purpose:
    - Minimal, fixed-supply ERC-20 token for the BattleDoge ecosystem.
    - Uses OpenZeppelin Contracts v5.4.0 ERC20 logic embedded directly (no imports).

    Key Properties:
    - Name:    Battle Doge
    - Symbol:  BDOGE
    - Decimals: 18 (OpenZeppelin default)
    - Total supply: 100,000,000 * 1e18 (fully minted once, in the constructor)
    - Minting: one-time mint in constructor to deployer (msg.sender)
    - No Permit, no Ownable/admin surface, no token-level sales/airdrop logic
    - "Burn" is done by sink-transfer at the application layer (token does not implement burn())
    - Reject accidental ETH transfers via receive()/fallback()
      NOTE: no contract can fully prevent forced ETH via SELFDESTRUCT; this only blocks normal sends.

    Security stance:
    - Keep ERC-20 surface area small and familiar.
    - No privileged roles or upgrade hooks.
*/

/**
 * @dev Custom error used to revert if someone tries to send ETH to this token contract.
 * Using a custom error is cheaper than revert strings.
 */
error ETHNotAccepted();

/* ============ OpenZeppelin Contracts (v5.4.0) — embedded ============ */
/* Source basis: OpenZeppelin Contracts v5.4.0 ERC20 + dependencies. */

/**
 * @dev Provides information about the current execution context (msg.sender, msg.data).
 * In meta-transaction systems, msg.sender may differ from the account paying gas.
 * Here we keep it standard, but inheriting this matches OpenZeppelin's structure.
 */
abstract contract Context {
    /// @dev Returns the sender of the transaction (or the relayer in meta-tx contexts).
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    /// @dev Returns the full calldata of the transaction.
    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    /**
     * @dev Used by some advanced meta-transaction patterns in OZ to strip context suffixes.
     * Default is zero; retained for compatibility with OZ's internal patterns.
     */
    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}

/**
 * @dev Interface of the ERC-20 standard (EIP-20).
 * This is the minimal external surface: transfer, approve, allowance, transferFrom, balances, totalSupply.
 */
interface IERC20 {
    /// @dev Emitted when `value` tokens move from `from` to `to`.
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @dev Emitted when `owner` sets `spender` allowance to `value`.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @dev Total token supply in existence.
    function totalSupply() external view returns (uint256);

    /// @dev Balance of a given account.
    function balanceOf(address account) external view returns (uint256);

    /// @dev Transfer tokens from caller to `to`.
    function transfer(address to, uint256 value) external returns (bool);

    /// @dev Allowance `spender` has from `owner`.
    function allowance(address owner, address spender) external view returns (uint256);

    /// @dev Approve `spender` to spend `value` from caller.
    function approve(address spender, uint256 value) external returns (bool);

    /// @dev Transfer tokens from `from` to `to` using allowance mechanism.
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/**
 * @dev Optional metadata functions from the ERC-20 standard (name/symbol/decimals).
 */
interface IERC20Metadata is IERC20 {
    /// @dev Human-readable token name.
    function name() external view returns (string memory);

    /// @dev Human-readable token symbol.
    function symbol() external view returns (string memory);

    /// @dev Number of decimals used to get the user representation (commonly 18).
    function decimals() external view returns (uint8);
}

/**
 * @dev ERC-6093 custom errors for ERC-20 tokens (the ERC-20 subset only).
 * These are standardized error names used by OpenZeppelin v5.x for clear revert reasons.
 */
interface IERC20Errors {
    /// @dev Thrown when an account tries to transfer/burn more tokens than it owns.
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /// @dev Thrown when a transfer/burn is initiated from the zero address.
    error ERC20InvalidSender(address sender);

    /// @dev Thrown when a transfer/mint is directed to the zero address.
    error ERC20InvalidReceiver(address receiver);

    /// @dev Thrown when allowance is insufficient for transferFrom / spendAllowance.
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    /// @dev Thrown when approve is attempted from the zero address.
    error ERC20InvalidApprover(address approver);

    /// @dev Thrown when approve is attempted to the zero address.
    error ERC20InvalidSpender(address spender);
}

/**
 * @dev OpenZeppelin ERC20 implementation (v5.4.0).
 *
 * Notes:
 * - v5.x centralizes all balance/supply changes in `_update(from, to, value)`:
 *   - mint:  from = address(0)
 *   - burn:  to   = address(0)
 *   - transfer: neither is zero
 * - This contract intentionally does NOT include EIP-2612 Permit or Ownable.
 */
abstract contract ERC20 is Context, IERC20, IERC20Metadata, IERC20Errors {
    /// @dev Mapping from account to balance.
    mapping(address account => uint256) private _balances;

    /// @dev Mapping owner => (spender => allowance).
    mapping(address account => mapping(address spender => uint256)) private _allowances;

    /// @dev Total token supply tracked by the contract.
    uint256 private _totalSupply;

    /// @dev Token name and symbol (immutable after construction).
    string private _name;
    string private _symbol;

    /**
     * @dev Sets token name and symbol at deployment time.
     * The derived token contract calls this via `ERC20("Name","SYM")`.
     */
    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    /// @inheritdoc IERC20Metadata
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /// @inheritdoc IERC20Metadata
    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    /**
     * @inheritdoc IERC20Metadata
     * OpenZeppelin default is 18, matching the common ERC-20 convention.
     */
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /// @inheritdoc IERC20
    function totalSupply() public view virtual returns (uint256) {
        return _totalSupply;
    }

    /// @inheritdoc IERC20
    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }

    /**
     * @inheritdoc IERC20
     * Moves `value` tokens from caller to `to`.
     * Returns true on success per ERC-20 convention.
     */
    function transfer(address to, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, value);
        return true;
    }

    /// @inheritdoc IERC20
    function allowance(address owner, address spender) public view virtual returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @inheritdoc IERC20
     * Sets allowance for `spender` to spend caller's tokens.
     */
    function approve(address spender, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, value);
        return true;
    }

    /**
     * @inheritdoc IERC20
     * Spends allowance from `from` by caller (spender), then transfers to `to`.
     */
    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }

    /**
     * @dev Internal transfer primitive.
     * Reverts if `from` or `to` is the zero address.
     * Actual balance/supply bookkeeping is performed in `_update`.
     */
    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        if (to == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(from, to, value);
    }

    /**
     * @dev Central accounting hook for transfers/mints/burns.
     *
     * Cases:
     * - Mint: from == address(0), to != address(0)
     * - Burn: from != address(0), to == address(0)
     * - Transfer: from != address(0), to != address(0)
     *
     * Emits a Transfer event in all cases (including mint/burn), per ERC-20 conventions.
     */
    function _update(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) {
            // Mint path: increase total supply
            // Overflow check required: The rest of the code assumes that totalSupply never overflows
            _totalSupply += value;
        } else {
            // Transfer/Burn path: decrease `from` balance
            uint256 fromBalance = _balances[from];
            if (fromBalance < value) {
                revert ERC20InsufficientBalance(from, fromBalance, value);
            }
            unchecked {
                // Overflow not possible: value <= fromBalance <= totalSupply.
                _balances[from] = fromBalance - value;
            }
        }

        if (to == address(0)) {
            // Burn path: reduce total supply
            unchecked {
                // Overflow not possible: value <= totalSupply or value <= fromBalance <= totalSupply.
                _totalSupply -= value;
            }
        } else {
            // Transfer/Mint path: increase `to` balance
            unchecked {
                // Overflow not possible: balance + value is at most totalSupply, which we know fits into a uint256.
                _balances[to] += value;
            }
        }

        // ERC-20 canonical event for all token movements.
        emit Transfer(from, to, value);
    }

    /**
     * @dev Creates `value` tokens and assigns them to `account`.
     * Reverts if `account` is the zero address.
     */
    function _mint(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(address(0), account, value);
    }

    /**
     * @dev Destroys `value` tokens from `account`, reducing total supply.
     * Reverts if `account` is the zero address.
     */
    function _burn(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        _update(account, address(0), value);
    }

    /**
     * @dev Internal approve with default behavior: emits Approval event.
     */
    function _approve(address owner, address spender, uint256 value) internal {
        _approve(owner, spender, value, true);
    }

    /**
     * @dev Internal approve primitive.
     * - `emitEvent` is used by `_spendAllowance` to avoid emitting Approval on transferFrom,
     *   saving gas and matching OZ v5 behavior.
     */
    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal virtual {
        if (owner == address(0)) {
            revert ERC20InvalidApprover(address(0));
        }
        if (spender == address(0)) {
            revert ERC20InvalidSpender(address(0));
        }

        _allowances[owner][spender] = value;

        if (emitEvent) {
            emit Approval(owner, spender, value);
        }
    }

    /**
     * @dev Spends `value` from the allowance of `owner` toward `spender`.
     *
     * Special case:
     * - If allowance is `type(uint256).max`, it is treated as "infinite" and not decreased.
     */
    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance < type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                // Update allowance without emitting Approval to save gas.
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }
}

/* ======================= BattleDogeToken ======================= */

/**
 * @title BattleDogeToken
 * @dev Fixed-supply ERC-20 token for the BattleDoge ecosystem.
 *
 * Deployment notes:
 * - Deployer address receives the full supply.
 * - There are no administrative functions after deployment.
 * - ETH sends are rejected (receive/fallback revert).
 */
contract BattleDogeToken is ERC20 {
    /**
     * @dev Total supply constant (100M tokens with 18 decimals).
     * Declared as a compile-time constant so it cannot be changed.
     */
    uint256 public constant TOTAL_SUPPLY = 100_000_000 * 1e18;

    /**
     * @dev Initializes the token name/symbol and mints the full supply to the deployer.
     */
    constructor() ERC20("Battle Doge", "BDOGE") {
        _mint(_msgSender(), TOTAL_SUPPLY);
    }

    /**
     * @dev Reject direct ETH transfers.
     * Users should not send ETH to an ERC-20 token contract.
     */
    receive() external payable {
        revert ETHNotAccepted();
    }

    /**
     * @dev Reject unknown calls and ETH transfers to non-existent functions.
     */
    fallback() external payable {
        revert ETHNotAccepted();
    }
}
