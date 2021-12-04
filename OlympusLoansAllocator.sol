// SPDX-License-Indentifier: MIT
pragma solidity 0.8.10;

// SafeERC20 - no imports required
// modifed from Rari-capital/solmate
library SafeERC20 {
    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        // IERC20.transfer.selector = 0x23b872dd
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
    }

    function safeTransfer(address token, address to, uint256 amount) internal {
        // IERC20.transfer.selector = 0xa9059cbb
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FAILED");
    }

    function safeApprove(address token, address to, uint256 amount) internal {
        // IERC20.transfer.selector = 0x095ea7b3
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, amount));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }
}

interface ITreasury {
    function deposit( uint _amount, address _token, uint _profit ) external returns ( uint send_ );
    function manage( address _token, uint _amount ) external;
    function valueOf( address _token, uint _amount ) external view returns ( uint value_ );
}

interface IStaking {
    function unstake(address _to, uint256 _amount, bool _trigger, bool _rebasing) external returns (uint256 amount_);
    function index() external view returns (uint256);
}

// Treasury allocates OHM to this contract, increasing max debt
// that OHM is lent out Alchemix style
// once total debt = max debt the contract stops lending OHM (because there's none to be lent)
// as users payback their loans, total debt decreases allowsing for laons again
// additionally, at any time the treasury can allocate more OHM to lend
contract OlympusLoansAllocator {

    using SafeERC20 for address;

    //////////////// STRUCTURED ////////////////

    struct UserInfo {
        uint256 collateral;
        uint256 debt;
        uint256 lastIndex;
    }

    // stores user info
    mapping(address => UserInfo) public userInfo;

    ////////////////// STORAGE //////////////////

    // representation of a whole number denominated in BIPS
    uint256 public constant DIVISOR_BIPS = 1e4;

    // max loan to value ratio denominated in BIPS - 50%
    uint256 public constant MAX_LTV_BIPS = 5e3;

    // total amount of OHM currently being borrowed
    uint256 public totalDebt;

    // max amount of OHM that can be lent out
    uint256 public maxDebt;

    // liquid payout token
    address public OHM;

    // loan collateral token
    address public sOHM;

    // staking contract
    address public staking;

    // OlympusDAO treasury
    ITreasury public treasury;

    //////////////////  INIT  //////////////////

    constructor(
        address _OHM, 
        address _sOHM, 
        address _staking, 
        ITreasury _treasury
    ) {
        OHM = _OHM;
        sOHM = _sOHM;
        staking = _staking;
        treasury = _treasury;
    }

    ////////////////// POLICY //////////////////

    function deposit(
        uint256 amount
    ) external {
        // borrow funds from treasury
        treasury.manage(OHM, amount);
        // increase max debt
        maxDebt += amount;
    }

    /// TODO add function to withdraw OHM

    ////////////////// PUBLIC //////////////////

    function selfLiquidate(uint256 amount) external {
        // user.debt -= debt paid since last interaction
        adjustDebt(msg.sender);      
        // interface user info
        UserInfo storage user = userInfo[msg.sender];
        // make sure user has enough debt to pay off
        require(user.debt >= amount, "debt too low");
        // unstake sOHM, indirectly paying back debt
        IStaking(staking).unstake(address(this), amount, false, true);
        // reduce users collateral
        user.collateral -= amount;
        // reduce users debt
        user.debt -= amount;
    }

    /// @notice borrow OHM, using your sOHM as collateral
    /// you can withdraw your sOHM once its interest has paid off your debt
    function takeLoan(
        uint256 input, 
        uint256 output
    ) external {
        // user.debt -= debt paid since last interaction
        adjustDebt(msg.sender);      
        // make sure user has enough collateral for loan
        require(maxLoanUser(msg.sender, input) >= output);
        // make sure there's enough liquidity to pay out loan
        require(output <= maxLoan(), "insufficient liquidity");
        // interface user info
        UserInfo storage user = userInfo[msg.sender];
        // pull users collateral
        sOHM.safeTransferFrom(msg.sender, address(this), input);
        // increase total debt
        totalDebt += output;
        // increase users collateral
        user.collateral += input;
        // increase users total debt
        user.debt += output;
        // push users loan
        OHM.safeTransfer(msg.sender, output);
    }

    /// @notice increase collateral
    function addCollateral(
        address account, 
        uint256 amount
    ) external {
        // user.debt -= debt paid since last interaction
        adjustDebt(account);
        // interface user info
        UserInfo storage user = userInfo[account];
        // pull users collateral
        sOHM.safeTransferFrom(msg.sender, address(this), amount);
        // increase users collateral
        user.collateral += amount;
    }

    /// @notice decrease collateral
    function removeCollateral(
        uint256 amount
    ) external {
        // user.debt -= debt paid since last interaction
        adjustDebt(msg.sender);
        // interface user info
        UserInfo storage user = userInfo[msg.sender];
        // make sure users LTV isn't too high
        require(userRemoveable(msg.sender) >= amount, "LTV too high");
        // reduce users collateral
        user.collateral -= amount;
        // push users tokens
        sOHM.safeTransfer(msg.sender, amount);
    }

    /// @notice pay off debt
    function repayDebt(
        address account, 
        uint256 input
    ) external {
        // user.debt -= debt paid since last interaction
        adjustDebt(account);
        // interface user info
        UserInfo storage user = userInfo[account];
        // pull users collateral
        OHM.safeTransferFrom(msg.sender, address(this), input);
        // reduce total debt
        totalDebt -= input;
        // reduce users debt
        user.debt -= input;
    }

    // needs reentrance protection
    function adjustDebt(address account) public returns (uint256) {
        // interface user info
        UserInfo storage user = userInfo[account];
        // if user debt is 0 return, because there's nothing to adjust
        if (user.debt == 0) return user.debt;
        // adjust users debt
        user.debt = adjustedDebt(account);
        // get current index
        uint256 currentIndex = IStaking(staking).index();
        // update last index
        user.lastIndex = currentIndex;
        // return new user debt
        return user.debt;
    }

    ////////////////// VIEW //////////////////

    /// @notice returns maximum loan size
    function maxLoan() public view returns (uint256) {
        if (maxDebt == 0) return 0;
        if (totalDebt >= maxDebt) return 0;
        return maxDebt - totalDebt;
    }

    /// @notice returns user.debt adjusted to account for interest paid since last interaction
    function adjustedDebt(address who) public view returns (uint256) {
        // interface user info
        UserInfo memory user = userInfo[who];
        // get current index
        uint256 currentIndex = IStaking(staking).index();
        // calc debt paid since last accrual
        uint256 paidDebt = user.debt * user.lastIndex / currentIndex;
        // return adjusted debt
        if (user.debt <= paidDebt) return 0;
        else return user.debt - paidDebt;
    }

    /// @notice returns max amount of collateral a user can remove
    function userRemoveable(
        address who
    ) public view returns (uint256) {
        // interface user info
        UserInfo memory user = userInfo[who];
        // get user LTV ratio
        uint256 _userLTV = userLTV(who, 0, 0);
        // calc available LTV
        uint256 availableLTV = MAX_LTV_BIPS - _userLTV;
        // calc and return 
        return user.collateral * availableLTV * 2 / DIVISOR_BIPS;
    }

    /// @notice returns users loan to value ratio
    function userLTV(
        address who,
        uint256 input, // optional 
        uint256 output // optional
    ) public view returns (uint256) {
        // interface user info
        UserInfo memory user = userInfo[who];
        // calc adjusted user debt
        uint256 _adjustedDebt = adjustedDebt(who) + output;
        // calc adjusted amount collateral to user
        uint256 adjustedCollateral = user.collateral + input;
        // calc and return users LTV
        return DIVISOR_BIPS * _adjustedDebt / adjustedCollateral;
    }

    /// @notice returns the maximum amount a user can loan
    function maxLoanUser(
        address who, 
        uint256 input // optional
    ) public view returns (uint256) {
        // interface user info
        UserInfo memory user = userInfo[who];
        // calc users adjusted collateral amount
        uint256 adjustedcollateral = user.collateral + input;
        // calc adjusted loan to value ratio for user
        uint256 adjustedLTV = DIVISOR_BIPS * adjustedDebt(who) / adjustedcollateral;
        // calc max available loan given the users input
        uint256 _maxUserLoan = user.collateral * adjustedLTV / DIVISOR_BIPS - adjustedDebt(who); 
        // if max user loan is greater than maximum possible loan
        if (_maxUserLoan > maxLoan()) {
            // return maximum possible loan
            return maxLoan();
        } else {
            // else return max user loan
            return _maxUserLoan;
        }
    }
}
