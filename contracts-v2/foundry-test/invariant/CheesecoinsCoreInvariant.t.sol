// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../../foundry-src/core/CheesecoinsCore.sol";
import "../../foundry-src/Config.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @notice Mock price feed used in invariant tests — returns peg price ($1.00) by default
 */
contract MockCurdUsdPriceFeedInvariant {
    int256 private _price;
    bool private _isStale;

    constructor(int256 price_, bool isStale_) {
        _price = price_;
        _isStale = isStale_;
    }

    function viewLatestPrice() external view returns (int256 price, bool isStale) {
        return (_price, _isStale);
    }
}

/**
 * @title CheesecoinsCoreInvariantTest
 * @notice Invariant fuzzing tests for CheesecoinsCore
 * @dev Tests critical invariants that must hold under all conditions
 */
contract CheesecoinsCoreInvariantTest is Test {
    CheesecoinsCore public core;
    InvariantHandler public handler;

    function setUp() public {
        // Deploy implementation
        CheesecoinsCore implementation = new CheesecoinsCore();

        // Deploy ProxyAdmin
        ProxyAdmin proxyAdmin = new ProxyAdmin();

        // Deploy proxy
        address treasuryEcosystem = makeAddr("treasuryEcosystem");
        address treasuryFarmers = makeAddr("treasuryFarmers");
        address treasuryMarketing = makeAddr("treasuryMarketing");
        address treasuryReserve = makeAddr("treasuryReserve");
        address auditor = makeAddr("auditor");
        address minter = makeAddr("minter");

        // Deploy mock price feed at peg ($1.00)
        MockCurdUsdPriceFeedInvariant mockFeed = new MockCurdUsdPriceFeedInvariant(int256(Config.PEG_PRICE), false);

        bytes memory initData = abi.encodeWithSelector(
            CheesecoinsCore.initialize.selector,
            treasuryEcosystem,
            treasuryFarmers,
            treasuryMarketing,
            treasuryReserve,
            auditor,
            minter,
            address(mockFeed),
            makeAddr("founderVestingWallet")
        );

        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);

        core = CheesecoinsCore(address(proxy));

        // Deploy handler
        handler = new InvariantHandler(core);

        // Target handler for invariant testing
        targetContract(address(handler));
    }

    /// @notice INVARIANT: Total supply must never exceed MAX_SUPPLY
    function invariant_totalSupplyNeverExceedsMax() public {
        assertLe(core.totalSupply(), Config.MAX_SUPPLY, "Total supply must never exceed MAX_SUPPLY");
    }

    /// @notice INVARIANT: Current year minted must never exceed annual cap
    function invariant_annualMintCapRespected() public {
        (uint256 minted, uint256 capacity,) = core.getAnnualMintStats();
        assertLe(minted, capacity, "Current year minted must not exceed annual capacity");
    }

    /// @notice INVARIANT: Annual capacity is always 2% of effective year start supply
    function invariant_annualCapacityCorrect() public {
        (, uint256 capacity,) = core.getAnnualMintStats();
        // Mirror getAnnualMintStats() view logic: if a year has expired the effective supply
        // is totalSupply() (the reset hasn't been committed yet), otherwise yearStartSupply.
        uint256 effectiveSupply = (block.timestamp >= core.lastMintResetTime() + Config.ONE_YEAR)
            ? core.totalSupply()
            : core.yearStartSupply();
        uint256 expectedCapacity = (effectiveSupply * Config.ANNUAL_MINT_CAP_PERCENT) / 100;
        assertEq(capacity, expectedCapacity, "Annual capacity must be 2% of year start supply");
    }

    /// @notice INVARIANT: Production value never decreases
    function invariant_productionValueMonotonic() public {
        // This is tracked by handler's ghost variable
        uint256 currentProduction = core.totalProductionValue();
        assertGe(currentProduction, handler.minProductionValue(), "Production value should be monotonically increasing");
    }

    /// @notice INVARIANT: Project count never decreases
    function invariant_projectCountMonotonic() public {
        assertGe(core.getProjectCount(), handler.minProjectCount(), "Project count should never decrease");
    }
}

/**
 * @title InvariantHandler
 * @notice Handler contract for invariant fuzzing
 * @dev Provides valid operations to test contract invariants
 */
contract InvariantHandler is Test {
    CheesecoinsCore public core;

    // Ghost variables to track state
    uint256 public minProductionValue;
    uint256 public minProjectCount;

    // Track operations for debugging
    uint256 public mintCount;
    uint256 public burnCount;
    uint256 public auditCount;

    constructor(CheesecoinsCore _core) {
        core = _core;
        minProductionValue = core.totalProductionValue();
        minProjectCount = core.getProjectCount();
    }

    /// @notice Fuzz mint operations
    function mint(uint256 productionGrowth) public {
        // Bound production growth to reasonable values
        productionGrowth = bound(productionGrowth, 1, 10_000_000 * 10 ** 18);

        uint256 newProduction = core.totalProductionValue() + productionGrowth;

        // Check if mint is possible
        (uint256 minted,, uint256 remaining) = core.getAnnualMintStats();
        if (remaining == 0) {
            // Skip if annual cap reached
            return;
        }

        if (core.totalSupply() + productionGrowth > Config.MAX_SUPPLY) {
            // Skip if would exceed max supply
            return;
        }

        vm.prank(core.authorizedMinter());
        try core.mintNewCURDForEcosystemGrowth(newProduction, "") {
            mintCount++;
            // Update ghost variable
            if (newProduction > minProductionValue) {
                minProductionValue = newProduction;
            }
        } catch {
            // Mint failed, that's okay
        }
    }

    /// @notice Fuzz burn operations
    function burn(uint256 amount) public {
        address treasury = core.treasuryEcosystem();
        uint256 balance = core.balanceOf(treasury);

        if (balance == 0) return;

        // Bound amount to available balance
        amount = bound(amount, 1, balance);

        vm.prank(treasury);
        try core.burn(amount) {
            burnCount++;
        } catch {
            // Burn failed, that's okay
        }
    }

    /// @notice Fuzz project registration
    function registerProject(uint256 initialDoes) public {
        // Bound initial does to reasonable values
        initialDoes = bound(initialDoes, 1, 10000);

        address nft = address(uint160(uint256(keccak256(abi.encodePacked("nft", core.getProjectCount())))));
        address oracle = address(uint160(uint256(keccak256(abi.encodePacked("oracle", core.getProjectCount())))));

        vm.prank(core.owner());
        try core.registerProject(nft, oracle, initialDoes) {
            uint256 currentCount = core.getProjectCount();
            if (currentCount > minProjectCount) {
                minProjectCount = currentCount;
            }
        } catch {
            // Registration failed, that's okay
        }
    }

    /// @notice Fuzz time warps
    function warpTime(uint256 timeToAdd) public {
        // Bound time to 0-2 years
        timeToAdd = bound(timeToAdd, 0, 2 * 365 days);
        vm.warp(block.timestamp + timeToAdd);
    }
}
