// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "forge-std/Test.sol";
import { ERC20 } from "solmate/tokens/ERC20.sol";
import { BaseTest } from "./base/BaseTest.t.sol";
import { TxBuilder } from "src/contracts/helpers/TxBuilder.sol";
import { SolverOperation } from "src/contracts/types/SolverCallTypes.sol";
import { UserOperation } from "src/contracts/types/UserCallTypes.sol";
import { DAppOperation, DAppConfig } from "src/contracts/types/DAppApprovalTypes.sol";
import { SwapIntent, SwapIntentInvertBidDAppControl } from "src/contracts/examples/intents-example/SwapIntentInvertBidDAppControl.sol";
import { SolverBaseInvertBid } from "src/contracts/solver/SolverBaseInvertBid.sol";

contract SwapIntentTest is BaseTest {
    SwapIntentInvertBidDAppControl public swapIntentControl;
    TxBuilder public txBuilder;
    Sig public sig;

    ERC20 DAI = ERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    address DAI_ADDRESS = address(DAI);

    struct Sig {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function setUp() public virtual override {
        BaseTest.setUp();

        // Creating new gov address (SignatoryActive error if already registered with control)
        governancePK = 11_112;
        governanceEOA = vm.addr(governancePK);

        // Deploy new SwapIntent Control from new gov and initialize in Atlas
        vm.startPrank(governanceEOA);
        swapIntentControl = new SwapIntentInvertBidDAppControl(address(atlas));
        atlasVerification.initializeGovernance(address(swapIntentControl));
        vm.stopPrank();

        txBuilder = new TxBuilder({
            _control: address(swapIntentControl),
            _atlas: address(atlas),
            _verification: address(atlasVerification)
        });

        // Deposit ETH from Searcher signer to pay for searcher's gas
        // vm.prank(solverOneEOA);
        // atlas.deposit{value: 1e18}();
    }

    function testAtlasSwapIntentInvertBidWithBasicRFQ() public {
        // Define hardcoded quantities
        uint256 amountUserBuys = 20e18;
        uint256 maxAmountUserSells = 10e18;
        uint256 solverBidAmount = 1e18;

        SwapIntent memory swapIntent = createSwapIntent(amountUserBuys, maxAmountUserSells);
        SimpleRFQSolverInvertBid rfqSolver = deployAndFundRFQSolver(swapIntent);
        address executionEnvironment = createExecutionEnvironment();
        UserOperation memory userOp = buildUserOperation(swapIntent);
        SolverOperation memory solverOp = buildSolverOperation(userOp, swapIntent, executionEnvironment, address(rfqSolver), solverBidAmount);
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;
        DAppOperation memory dAppOp = buildDAppOperation(userOp, solverOps);

        uint256 userWethBalanceBefore = WETH.balanceOf(userEOA);
        uint256 userDaiBalanceBefore = DAI.balanceOf(userEOA);

        vm.prank(userEOA); 
        WETH.transfer(address(1), userWethBalanceBefore - swapIntent.maxAmountUserSells);
        userWethBalanceBefore = WETH.balanceOf(userEOA);
        assertTrue(userWethBalanceBefore >= swapIntent.maxAmountUserSells, "Not enough starting WETH");

        approveAtlasAndExecuteSwap(swapIntent, userOp, solverOps, dAppOp);

        // Check user token balances after
        assertEq(WETH.balanceOf(userEOA), userWethBalanceBefore - solverBidAmount, "Did not spend WETH == solverBidAmount");
        assertEq(DAI.balanceOf(userEOA), userDaiBalanceBefore + swapIntent.amountUserBuys, "Did not receive enough DAI");
    }

    function createSwapIntent(uint256 amountUserBuys, uint256 maxAmountUserSells) internal view returns (SwapIntent memory) {
        return SwapIntent({
            tokenUserBuys: DAI_ADDRESS,
            amountUserBuys: amountUserBuys,
            tokenUserSells: WETH_ADDRESS,
            maxAmountUserSells: maxAmountUserSells
        });
    }

    function deployAndFundRFQSolver(SwapIntent memory swapIntent) internal returns (SimpleRFQSolverInvertBid) {
        vm.startPrank(solverOneEOA);
        SimpleRFQSolverInvertBid rfqSolver = new SimpleRFQSolverInvertBid(WETH_ADDRESS, address(atlas));
        atlas.deposit{ value: 1e18 }();
        atlas.bond(1 ether);
        vm.stopPrank();

        deal(DAI_ADDRESS, address(rfqSolver), swapIntent.amountUserBuys);
        assertEq(DAI.balanceOf(address(rfqSolver)), swapIntent.amountUserBuys, "Did not give enough DAI to solver");

        return rfqSolver;
    }

    function createExecutionEnvironment() internal returns (address){
        vm.startPrank(userEOA);
        address executionEnvironment = atlas.createExecutionEnvironment(txBuilder.control());
        console.log("executionEnvironment", executionEnvironment);
        vm.stopPrank();
        vm.label(address(executionEnvironment), "EXECUTION ENV");

        return executionEnvironment;
    }

    function buildUserOperation(SwapIntent memory swapIntent) internal view returns (UserOperation memory) {
        UserOperation memory userOp;

        bytes memory userOpData = abi.encodeCall(SwapIntentInvertBidDAppControl.swap, swapIntent);

        userOp = txBuilder.buildUserOperation({
            from: userEOA,
            to: address(swapIntentControl),
            maxFeePerGas: tx.gasprice + 1,
            value: 0,
            deadline: block.number + 2,
            data: userOpData
        });
        userOp.sessionKey = governanceEOA;

        return userOp;
    }

    function buildSolverOperation(UserOperation memory userOp, SwapIntent memory swapIntent, address executionEnvironment,
        address solverAddress, uint256 solverBidAmount) internal returns (SolverOperation memory) {
        bytes memory solverOpData =
            abi.encodeCall(SimpleRFQSolverInvertBid.fulfillRFQ, (swapIntent, executionEnvironment, solverBidAmount));

        SolverOperation memory solverOp = txBuilder.buildSolverOperation({
            userOp: userOp,
            solverOpData: solverOpData,
            solverEOA: solverOneEOA,
            solverContract: solverAddress,
            bidAmount: solverBidAmount,
            value: 0
        });

        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOp));
        solverOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        return solverOp;
    }

    function buildDAppOperation(UserOperation memory userOp, SolverOperation[] memory solverOps) 
        internal returns (DAppOperation memory) {
        DAppOperation memory dAppOp = txBuilder.buildDAppOperation(governanceEOA, userOp, solverOps);

        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        return dAppOp;
    }

    function approveAtlasAndExecuteSwap(SwapIntent memory swapIntent, UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) internal {
        vm.startPrank(userEOA);

        (bool simResult,,) = simulator.simUserOperation(userOp);
        assertFalse(simResult, "metasimUserOperationcall tested true a");

        WETH.approve(address(atlas), swapIntent.maxAmountUserSells);

        (simResult,,) = simulator.simUserOperation(userOp);
        assertTrue(simResult, "metasimUserOperationcall tested false c");
        uint256 gasLeftBefore = gasleft();

        vm.startPrank(userEOA);
        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp });

        console.log("Metacall Gas Cost:", gasLeftBefore - gasleft());
        vm.stopPrank();
    }
}

// This solver magically has the tokens needed to fulfil the user's swap.
// This might involve an offchain RFQ system
contract SimpleRFQSolverInvertBid is SolverBaseInvertBid {
    constructor(address weth, address atlas) SolverBaseInvertBid(weth, atlas, msg.sender, false) { }

    function fulfillRFQ(SwapIntent calldata swapIntent, address executionEnvironment, uint256 solverBidAmount) public {
        require(
            ERC20(swapIntent.tokenUserSells).balanceOf(address(this)) >= solverBidAmount,
            "Did not receive enough tokenUserSells (=solverBidAmount) to fulfill swapIntent"
        );
        require(
            ERC20(swapIntent.tokenUserBuys).balanceOf(address(this)) >= swapIntent.amountUserBuys,
            "Not enough tokenUserBuys to fulfill"
        );
        ERC20(swapIntent.tokenUserBuys).transfer(executionEnvironment, swapIntent.amountUserBuys);
    }

    // This ensures a function can only be called through atlasSolverCall
    // which includes security checks to work safely with Atlas
    modifier onlySelf() {
        require(msg.sender == address(this), "Not called via atlasSolverCall");
        _;
    }

    fallback() external payable { }
    receive() external payable { }
}
