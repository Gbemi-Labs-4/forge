// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRouterB {
    function swapExactETHForTokens(uint a, address[] calldata p, address to, uint d) external payable returns (uint[] memory);
    function swapExactTokensForETH(uint a, uint b, address[] calldata p, address to, uint d) external returns (uint[] memory);
}
interface IERC20B {
    function approve(address, uint) external returns (bool);
    function balanceOf(address) external view returns (uint);
}

/// Fires a buy (and optional sell) each block so the token stays hot on the flashblock feed.
contract BaitKeeper {
    address public owner;
    address public router;
    address public token;
    address public weth;
    uint256 public baitSize;

    constructor(address _router, address _token, address _weth) {
        owner = msg.sender; router = _router; token = _token; weth = _weth;
    }
    receive() external payable {}
    function setBait(uint256 wei_) external { require(msg.sender == owner, "auth"); baitSize = wei_; }

    function bait() external {
        require(msg.sender == owner, "auth");
        address[] memory p = new address[](2);
        p[0] = weth; p[1] = token;
        IRouterB(router).swapExactETHForTokens{value: baitSize}(0, p, address(this), block.timestamp);

        uint bal = IERC20B(token).balanceOf(address(this));
        IERC20B(token).approve(router, bal);
        p[0] = token; p[1] = weth;
        IRouterB(router).swapExactTokensForETH(bal, 0, p, address(this), block.timestamp);
    }

    function withdraw() external {
        require(msg.sender == owner, "auth");
        (bool ok, ) = payable(owner).call{value: address(this).balance}(""); require(ok);
    }
}