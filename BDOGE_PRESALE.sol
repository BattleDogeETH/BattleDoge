// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/*
    FixedPriceTokenSale.sol (auditor-patched)

    Sells an ERC-20 token held by this contract for ETH at a fixed price.

    Pricing model:
      - priceWeiPerTokenUnit = wei required to buy `tokenUnit` token units
      - tokenUnit is typically 10**decimals (e.g. 1e18 for 18-decimal tokens)

    tokensOut = (msg.value * tokenUnit) / priceWeiPerTokenUnit

    Operational note:
      - Contract deploys PAUSED by default. Fund it with tokens, then unpause.
*/

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/* ============ Minimal utilities ============ */

library SafeERC20 {
    error SafeERC20CallFailed();
    error SafeERC20BadReturn();

    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, amount));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, amount));
    }

    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        (bool ok, bytes memory ret) = address(token).call(data);
        if (!ok) revert SafeERC20CallFailed();
        if (ret.length == 0) return; // non-standard ERC20: assume success
        if (ret.length == 32) {
            bool success = abi.decode(ret, (bool));
            if (!success) revert SafeERC20BadReturn();
            return;
        }
        revert SafeERC20BadReturn();
    }
}

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    error Reentrancy();

    modifier nonReentrant() {
        if (_status == _ENTERED) revert Reentrancy();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

abstract contract Ownable2Step {
    address public owner;
    address public pendingOwner;

    error NotOwner();
    error ZeroAddress();

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        address po = pendingOwner;
        if (msg.sender != po) revert NotOwner();
        address prev = owner;
        owner = po;
        pendingOwner = address(0);
        emit OwnershipTransferred(prev, po);
    }
}

library Math512 {
    // OpenZeppelin-style mulDiv: floor(x * y / d) with full precision
    function mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                return prod0 / d;
            }
            require(d > prod1, "mulDiv overflow");

            uint256 remainder;
            assembly {
                remainder := mulmod(x, y, d)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = d & (~d + 1);
            assembly {
                d := div(d, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inv = (3 * d) ^ 2;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;

            result = prod0 * inv;
            return result;
        }
    }
}

/* ============ Sale contract ============ */

contract FixedPriceTokenSale is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error SalePaused();          // buying blocked because paused == true
    error SaleNotPaused();       // admin action requires paused == true
    error InvalidPrice();
    error ZeroETH();
    error ZeroTokensOut();
    error CannotRecoverSaleToken();
    error Slippage(uint256 minOut, uint256 actualOut);
    error InsufficientTokens(uint256 available, uint256 needed);
    error EthForwardFailed();

    event TokensPurchased(address indexed buyer, address indexed recipient, uint256 ethIn, uint256 tokensOut);
    event PriceUpdated(uint256 oldPriceWeiPerTokenUnit, uint256 newPriceWeiPerTokenUnit);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event Paused(bool isPaused);
    event SweptETH(address indexed to, uint256 amount);
    event WithdrawnTokens(address indexed to, uint256 amount);
    event RecoveredERC20(address indexed token, address indexed to, uint256 amount);

    IERC20 public immutable saleToken;
    uint256 public immutable tokenUnit;

    address public treasury;
    uint256 public priceWeiPerTokenUnit;
    bool public paused;

    uint256 public totalEthRaised;
    uint256 public totalTokensSold;

    constructor(
        address initialOwner,
        address token_,
        address treasury_,
        uint256 tokenUnit_,
        uint256 priceWeiPerTokenUnit_
    ) Ownable2Step(initialOwner) {
        if (token_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (tokenUnit_ == 0) revert InvalidPrice();
        if (priceWeiPerTokenUnit_ == 0) revert InvalidPrice();

        saleToken = IERC20(0x2C724d1FcA1B3D471EBAa004a054621aF85D417C);
        treasury = treasury_;
        tokenUnit = tokenUnit_;
        priceWeiPerTokenUnit = priceWeiPerTokenUnit_;

        // Auditor patch: align with operational guidance (deploy paused, fund, then unpause).
        paused = true;
        emit Paused(true);
    }

    /* ---------- User flow ---------- */

    function quoteTokens(uint256 ethAmountWei) public view returns (uint256) {
        // tokensOut = eth * tokenUnit / price
        return Math512.mulDiv(ethAmountWei, tokenUnit, priceWeiPerTokenUnit);
    }

    function buy(address recipient, uint256 minTokensOut)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        tokensOut = _buy(msg.sender, recipient, msg.value, minTokensOut);
    }

    // Convenience: send ETH directly to the contract to buy for yourself (minTokensOut = 0).
    receive() external payable nonReentrant {
        _buy(msg.sender, msg.sender, msg.value, 0);
    }

    function _buy(address buyer, address recipient, uint256 ethIn, uint256 minTokensOut)
        internal
        returns (uint256 tokensOut)
    {
        if (paused) revert SalePaused();
        if (ethIn == 0) revert ZeroETH();
        if (recipient == address(0)) revert ZeroAddress();

        tokensOut = quoteTokens(ethIn);
        if (tokensOut == 0) revert ZeroTokensOut();
        if (tokensOut < minTokensOut) revert Slippage(minTokensOut, tokensOut);

        uint256 available = saleToken.balanceOf(address(this));
        if (tokensOut > available) revert InsufficientTokens(available, tokensOut);

        // effects
        totalEthRaised += ethIn;
        totalTokensSold += tokensOut;

        // interactions
        saleToken.safeTransfer(recipient, tokensOut);

        // forward ETH to treasury (no ETH should sit here under normal use)
        (bool ok, ) = treasury.call{value: ethIn}("");
        if (!ok) revert EthForwardFailed();

        emit TokensPurchased(buyer, recipient, ethIn, tokensOut);
    }

    /* ---------- Admin controls ---------- */

    function setPrice(uint256 newPriceWeiPerTokenUnit) external onlyOwner {
        if (newPriceWeiPerTokenUnit == 0) revert InvalidPrice();
        uint256 old = priceWeiPerTokenUnit;
        priceWeiPerTokenUnit = newPriceWeiPerTokenUnit;
        emit PriceUpdated(old, newPriceWeiPerTokenUnit);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit Paused(p);
    }

    // Withdraw unsold tokens. Requires pause to reduce operational foot-guns.
    function withdrawUnsoldTokens(address to, uint256 amount) external onlyOwner nonReentrant {
        if (!paused) revert SaleNotPaused();
        if (to == address(0)) revert ZeroAddress();
        saleToken.safeTransfer(to, amount);
        emit WithdrawnTokens(to, amount);
    }

    // Recover any other ERC20 accidentally sent here. Requires pause for operational safety.
    function recoverERC20(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (!paused) revert SaleNotPaused();
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (token == address(saleToken)) revert CannotRecoverSaleToken();
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit RecoveredERC20(token, to, amount);
    }

    // Sweep ETH that was forced into this contract (SELFDESTRUCT) or stuck for any reason.
    function sweepETH(address to, uint256 amountWei) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        (bool ok, ) = to.call{value: amountWei}("");
        if (!ok) revert EthForwardFailed();
        emit SweptETH(to, amountWei);
    }

    /* ---------- Views ---------- */

    function remainingTokens() external view returns (uint256) {
        return saleToken.balanceOf(address(this));
    }
}
