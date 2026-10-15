// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ClaimsPool
/// @notice A minimal on-chain insurance pool: the insurer funds a reserve and
/// verifies customers (KYC); verified customers buy time-limited cover by
/// paying a premium; they file claims against their cover; the insurer
/// approves or rejects each claim; approved amounts are withdrawn by the
/// customer (pull payments, so a failing receiver cannot block the pool).
/// @dev Solvency invariant: the contract's balance always covers every
/// approved but unwithdrawn payout (`owed`).
contract ClaimsPool {
    enum ClaimState { None, Filed, Approved, Rejected }

    struct Policy {
        uint256 coverage;   // maximum total payout, in wei
        uint256 claimed;    // approved payouts so far
        uint64 expiry;      // unix time after which no claim can be filed
    }

    struct Claim {
        address customer;
        uint256 amount;
        ClaimState state;
    }

    address public immutable insurer;
    uint256 public immutable premiumBps;   // premium as basis points of coverage
    uint64 public immutable term;          // cover duration, seconds

    mapping(address => bool) public verified;
    mapping(address => Policy) public policies;
    mapping(address => uint256) public withdrawable;
    Claim[] public claims;
    uint256 public owed;                   // approved payouts not yet withdrawn

    event Verified(address indexed customer, bool status);
    event PolicyBought(address indexed customer, uint256 coverage, uint256 premium, uint64 expiry);
    event ClaimFiled(uint256 indexed id, address indexed customer, uint256 amount);
    event ClaimDecided(uint256 indexed id, bool approved);
    event Withdrawn(address indexed customer, uint256 amount);

    error NotInsurer();
    error NotVerified();
    error WrongPremium(uint256 expected, uint256 sent);
    error PolicyActive();
    error NoActivePolicy();
    error ExceedsCoverage(uint256 remaining, uint256 requested);
    error NotPending();
    error InsufficientReserve(uint256 available, uint256 needed);
    error NothingToWithdraw();
    error TransferFailed();

    modifier onlyInsurer() {
        if (msg.sender != insurer) revert NotInsurer();
        _;
    }

    constructor(uint256 premiumBps_, uint64 term_) payable {
        insurer = msg.sender;
        premiumBps = premiumBps_;
        term = term_;
    }

    /// @notice The insurer (or anyone) can add to the reserve.
    receive() external payable {}

    function setVerified(address customer, bool status) external onlyInsurer {
        verified[customer] = status;
        emit Verified(customer, status);
    }

    function premiumFor(uint256 coverage) public view returns (uint256) {
        return coverage * premiumBps / 10_000;
    }

    /// @notice Buy cover; a new policy can only start once the previous one has expired.
    function buyPolicy(uint256 coverage) external payable {
        if (!verified[msg.sender]) revert NotVerified();
        if (policies[msg.sender].expiry > block.timestamp) revert PolicyActive();
        uint256 premium = premiumFor(coverage);
        if (msg.value != premium) revert WrongPremium(premium, msg.value);
        uint64 expiry = uint64(block.timestamp) + term;
        policies[msg.sender] = Policy({coverage: coverage, claimed: 0, expiry: expiry});
        emit PolicyBought(msg.sender, coverage, premium, expiry);
    }

    function fileClaim(uint256 amount) external returns (uint256 id) {
        Policy storage p = policies[msg.sender];
        if (p.expiry <= block.timestamp) revert NoActivePolicy();
        uint256 remaining = p.coverage - p.claimed;
        if (amount == 0 || amount > remaining) revert ExceedsCoverage(remaining, amount);
        id = claims.length;
        claims.push(Claim({customer: msg.sender, amount: amount, state: ClaimState.Filed}));
        emit ClaimFiled(id, msg.sender, amount);
    }

    /// @notice Approve or reject a filed claim. Approval re-checks the remaining
    /// cover (several claims may be pending) and the free reserve.
    function decide(uint256 id, bool approve) external onlyInsurer {
        Claim storage c = claims[id];
        if (c.state != ClaimState.Filed) revert NotPending();
        if (!approve) {
            c.state = ClaimState.Rejected;
            emit ClaimDecided(id, false);
            return;
        }
        Policy storage p = policies[c.customer];
        uint256 remaining = p.coverage - p.claimed;
        if (c.amount > remaining) revert ExceedsCoverage(remaining, c.amount);
        uint256 free = address(this).balance - owed;
        if (c.amount > free) revert InsufficientReserve(free, c.amount);

        c.state = ClaimState.Approved;
        p.claimed += c.amount;
        owed += c.amount;
        withdrawable[c.customer] += c.amount;
        emit ClaimDecided(id, true);
    }

    /// @notice Pull an approved payout (checks-effects-interactions).
    function withdraw() external {
        uint256 amount = withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        withdrawable[msg.sender] = 0;
        owed -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice The insurer can take out surplus, never money owed to customers.
    function withdrawSurplus(uint256 amount) external onlyInsurer {
        uint256 free = address(this).balance - owed;
        if (amount > free) revert InsufficientReserve(free, amount);
        (bool ok,) = insurer.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function claimCount() external view returns (uint256) {
        return claims.length;
    }
}
