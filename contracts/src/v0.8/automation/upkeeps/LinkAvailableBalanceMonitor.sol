// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import {AutomationCompatibleInterface} from "../interfaces/AutomationCompatibleInterface.sol";
import {ConfirmedOwner} from "../../shared/access/ConfirmedOwner.sol";
import {EnumerableMap} from "../../vendor/openzeppelin-solidity/v4.8.3/contracts/utils/structs/EnumerableMap.sol";
import {IERC20} from "../../vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "../../vendor/openzeppelin-solidity/v4.8.3/contracts/security/Pausable.sol";

interface IAggregatorProxy {
  function aggregator() external view returns (address);
}

interface ILinkAvailable {
  function linkAvailableForPayment() external view returns (int256 availableBalance);
}

/// @title The LinkAvailableBalanceMonitor contract.
/// @notice A keeper-compatible contract that monitors target contracts for balance from a custom
/// function linkAvailableForPayment() and funds them with LINK if it falls below a defined
/// threshold. Also supports aggregator proxy contracts monitoring which require fetching the actual
/// target contract through a predefined interface.
/// @dev with 30 addresses as the s_maxPerform, the measured max gas usage of performUpkeep is around 2M
/// therefore, we recommend an upkeep gas limit of 3M (this has a 33% margin of safety). Although, nothing
/// prevents us from using 5M gas and increasing s_maxPerform, 30 seems like a reasonable batch size that
/// is probably plenty for most needs.
/// @dev with 130 addresses as the s_maxCheck, the measured max gas usage of checkUpkeep is around 3.5M,
/// which is 30% below the 5M limit.
/// Note that testing conditions DO NOT match live chain gas usage, hence the margins. Change
/// at your own risk!!!
/// @dev some areas for improvement / acknowledgement of limitations:
///  validate that all addresses conform to interface when adding them to the watchlist
///  this is a "trusless" upkeep, meaning it does not trust the caller of performUpkeep;
/// we could save a fair amount of gas and re-write this upkeep for use with Automation v2.0+,
/// which has significantly different trust assumptions
contract LinkAvailableBalanceMonitor is ConfirmedOwner, Pausable, AutomationCompatibleInterface {
  using EnumerableMap for EnumerableMap.AddressToUintMap;

  event FundsWithdrawn(uint256 amountWithdrawn, address payee);
  event TopUpSucceeded(address indexed topUpAddress);
  event TopUpBlocked(address indexed topUpAddress);
  event WatchlistUpdated();
  event MaxPerformUpdated(uint256 oldMaxPerform, uint256 newMaxPerform);
  event MaxCheckUpdated(uint256 oldMaxCheck, uint256 newMaxCheck);

  error InvalidWatchList();
  error DuplicateAddress(address duplicate);

  IERC20 private immutable LINK_TOKEN;
  EnumerableMap.AddressToUintMap private s_watchList;
  uint256 private s_topUpAmount;
  uint32 private s_minWaitPeriodSeconds;
  uint16 private s_maxPerform;
  uint16 private s_maxCheck;

  /// @param linkTokenAddress the LINK token address
  /// @param topUpAmount the amount of LINK to top up an aggregator with at once
  constructor(
    address linkTokenAddress,
    uint256 topUpAmount,
    uint16 maxPerform,
    uint16 maxCheck
  ) ConfirmedOwner(msg.sender) {
    require(linkTokenAddress != address(0), "LinkAvailableBalanceMonitor: invalid linkTokenAddress");
    require(topUpAmount > 0, "LinkAvailableBalanceMonitor: invalid topUpAmount");
    LINK_TOKEN = IERC20(linkTokenAddress);
    s_topUpAmount = topUpAmount;
    s_maxPerform = maxPerform;
    s_maxCheck = maxCheck;
  }

  /// @notice Sets the list of subscriptions to watch and their funding parameters
  /// @param addresses the list of target addresses to watch (could be direct target or IAggregatorProxy)
  /// @param minBalances the list of corresponding minBalance for the target address
  function setWatchList(address[] calldata addresses, uint256[] calldata minBalances) external onlyOwner {
    if (addresses.length != minBalances.length) {
      revert InvalidWatchList();
    }
    // first, remove all existing addresses from list
    for (uint256 idx = s_watchList.length(); idx > 0; idx--) {
      (address target, ) = s_watchList.at(idx - 1);
      require(s_watchList.remove(target), "LinkAvailableBalanceMonitor: unable to setWatchlist");
    }
    // then set new addresses
    for (uint256 idx = 0; idx < addresses.length; idx++) {
      if (s_watchList.contains(addresses[idx])) {
        revert DuplicateAddress(addresses[idx]);
      }
      if (addresses[idx] == address(0)) {
        revert InvalidWatchList();
      }
      s_watchList.set(addresses[idx], minBalances[idx]);
    }
    emit WatchlistUpdated();
  }

  /// @notice Adds addresses to the watchlist without overwriting existing members
  /// @param addresses the list of target addresses to watch (could be direct target or IAggregatorProxy)
  /// @param minBalances the list of corresponding minBalance for the target address
  function addToWatchList(address[] calldata addresses, uint256[] calldata minBalances) external onlyOwner {
    if (addresses.length != minBalances.length) {
      revert InvalidWatchList();
    }
    for (uint256 idx = 0; idx < addresses.length; idx++) {
      if (s_watchList.contains(addresses[idx])) {
        revert DuplicateAddress(addresses[idx]);
      }
      if (addresses[idx] == address(0)) {
        revert InvalidWatchList();
      }
      s_watchList.set(addresses[idx], minBalances[idx]);
    }
    emit WatchlistUpdated();
  }

  /// @notice Removes addresses from the watchlist
  /// @param addresses the list of target addresses to remove from the watchlist
  function removeFromWatchlist(address[] calldata addresses) external onlyOwner {
    for (uint256 idx = 0; idx < addresses.length; idx++) {
      if (!s_watchList.contains(addresses[idx])) {
        revert InvalidWatchList();
      }
      s_watchList.remove(addresses[idx]);
    }
    emit WatchlistUpdated();
  }

  /// @notice Gets a list of proxies that are underfunded, up to the s_maxPerform size
  /// @dev the function starts at a random index in the list to avoid biasing the first
  /// addresses in the list over latter ones.
  /// @dev the function will check at most s_maxCheck proxies in a single call
  /// @dev the function returns a list with a max length of s_maxPerform
  /// @return list of target addresses which are underfunded
  function sampleUnderfundedAddresses() public view returns (address[] memory) {
    uint16 maxPerform = s_maxPerform;
    uint16 maxCheck = s_maxCheck;
    uint256 numTargets = s_watchList.length();
    uint256 idx = uint256(blockhash(block.number - 1)) % numTargets; // start at random index, to distribute load
    uint256 numToCheck = numTargets < maxCheck ? numTargets : maxCheck;
    uint256 numFound = 0;
    address[] memory targetsToFund = new address[](maxPerform);
    for (
      uint256 numChecked = 0;
      numChecked < numToCheck;
      (idx, numChecked) = ((idx + 1) % numTargets, numChecked + 1)
    ) {
      (address target, uint256 minBalance) = s_watchList.at(idx);
      (bool needsFunding, ) = _needsFunding(target, minBalance);
      if (needsFunding) {
        targetsToFund[numFound] = target;
        numFound++;
        if (numFound == maxPerform) {
          break; // max number of addresses in batch reached
        }
      }
    }
    if (numFound != maxPerform) {
      assembly {
        mstore(targetsToFund, numFound) // resize array to number of valid targets
      }
    }
    return targetsToFund;
  }

  /// @notice Send funds to the targets provided.
  /// @param targetAddresses the list of targets to fund
  function topUp(address[] memory targetAddresses) public whenNotPaused {
    uint256 topUpAmount = s_topUpAmount;
    uint256 stopIdx = targetAddresses.length;
    uint256 numCanFund = LINK_TOKEN.balanceOf(address(this)) / topUpAmount;
    stopIdx = numCanFund < stopIdx ? numCanFund : stopIdx;
    for (uint256 idx = 0; idx < stopIdx; idx++) {
      (bool exists, uint256 minBalance) = s_watchList.tryGet(targetAddresses[idx]);
      if (!exists) {
        emit TopUpBlocked(targetAddresses[idx]);
        continue;
      }
      (bool needsFunding, address target) = _needsFunding(targetAddresses[idx], minBalance);
      if (!needsFunding) {
        emit TopUpBlocked(targetAddresses[idx]);
        continue;
      }
      LINK_TOKEN.transfer(target, topUpAmount);
      emit TopUpSucceeded(targetAddresses[idx]);
    }
  }

  /// @notice Gets list of subscription ids that are underfunded and returns a keeper-compatible payload.
  /// @return upkeepNeeded signals if upkeep is needed
  /// @return performData is an abi encoded list of subscription ids that need funds
  function checkUpkeep(
    bytes calldata
  ) external view override whenNotPaused returns (bool upkeepNeeded, bytes memory performData) {
    address[] memory needsFunding = sampleUnderfundedAddresses();
    uint256 numCanFund = LINK_TOKEN.balanceOf(address(this)) / s_topUpAmount;
    if (numCanFund < needsFunding.length) {
      assembly {
        mstore(needsFunding, numCanFund) // resize
      }
    }
    upkeepNeeded = needsFunding.length > 0;
    performData = abi.encode(needsFunding);
    return (upkeepNeeded, performData);
  }

  /// @notice Called by the keeper to send funds to underfunded addresses.
  /// @param performData the abi encoded list of addresses to fund
  function performUpkeep(bytes calldata performData) external override {
    address[] memory needsFunding = abi.decode(performData, (address[]));
    topUp(needsFunding);
  }

  /// @notice Withdraws the contract balance in the LINK token.
  /// @param amount the amount of the LINK to withdraw
  /// @param payee the address to pay
  function withdraw(uint256 amount, address payable payee) external onlyOwner {
    require(payee != address(0), "LinkAvailableBalanceMonitor: invalid payee address");
    LINK_TOKEN.transfer(payee, amount);
    emit FundsWithdrawn(amount, payee);
  }

  /// @notice Sets the top up amount
  function setTopUpAmount(uint256 topUpAmount) external onlyOwner returns (uint256) {
    require(topUpAmount > 0, "LinkAvailableBalanceMonitor: invalid linkTokenAddress");
    return s_topUpAmount = topUpAmount;
  }

  /// @notice Sets the minimum balance for the given target address
  function setMinBalance(address target, uint256 minBalance) external onlyOwner returns (uint256) {
    require(minBalance > 0, "LinkAvailableBalanceMonitor: invalid minBalance");
    (bool exists, uint256 prevMinBalance) = s_watchList.tryGet(target);
    if (!exists) {
      revert InvalidWatchList();
    }
    s_watchList.set(target, minBalance);
    return prevMinBalance;
  }

  /// @notice Update s_maxPerform
  function setMaxPerform(uint16 maxPerform) external onlyOwner {
    emit MaxPerformUpdated(s_maxPerform, maxPerform);
    s_maxPerform = maxPerform;
  }

  /// @notice Update s_maxCheck
  function setMaxCheck(uint16 maxCheck) external onlyOwner {
    emit MaxCheckUpdated(s_maxCheck, maxCheck);
    s_maxCheck = maxCheck;
  }

  /// @notice Gets maxPerform
  function getMaxPerform() external view returns (uint16) {
    return s_maxPerform;
  }

  /// @notice Gets maxCheck
  function getMaxCheck() external view returns (uint16) {
    return s_maxCheck;
  }

  /// @notice Gets the list of subscription ids being watched
  function getWatchList() external view returns (address[] memory, uint256[] memory) {
    uint256 len = s_watchList.length();
    address[] memory targets = new address[](len);
    uint256[] memory minBalances = new uint256[](len);

    for (uint256 idx = 0; idx < len; idx++) {
      (targets[idx], minBalances[idx]) = s_watchList.at(idx);
    }

    return (targets, minBalances);
  }

  /// @notice Gets the configured top up amount
  function getTopUpAmount() external view returns (uint256) {
    return s_topUpAmount;
  }

  /// @notice Gets the configured minimum balance for the given target
  function getMinBalance(address target) external view returns (uint256) {
    (bool exists, uint256 minBalance) = s_watchList.tryGet(target);
    if (!exists) {
      revert InvalidWatchList();
    }
    return minBalance;
  }

  /// @notice Pause the contract, which prevents executing performUpkeep
  function pause() external onlyOwner {
    _pause();
  }

  /// @notice Unpause the contract
  function unpause() external onlyOwner {
    _unpause();
  }

  /// @notice checks the target (could be direct target or IAggregatorProxy), and determines
  /// if it is elligible for funding
  /// @param targetAddress the target to check
  /// @param minBalance minimum balance required for the target
  /// @return bool whether the target needs funding or not
  /// @return address the address of the contract needing funding
  function _needsFunding(address targetAddress, uint256 minBalance) private view returns (bool, address) {
    ILinkAvailable target;
    IAggregatorProxy proxy = IAggregatorProxy(targetAddress);
    try proxy.aggregator() returns (address aggregatorAddress) {
      target = ILinkAvailable(aggregatorAddress);
    } catch {
      target = ILinkAvailable(targetAddress);
    }
    try target.linkAvailableForPayment() returns (int256 balance) {
      if (balance < 0 || uint256(balance) < minBalance) {
        return (true, address(target));
      }
    } catch {}
    return (false, address(0));
  }
}
