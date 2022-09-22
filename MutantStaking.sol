pragma solidity ^0.8.13;

import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./MintableToken.sol";

contract MutantStaking is OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;
    using SafeMathUpgradeable for uint256;

    // Proxy variables;
    address __delegate;
    address __owner;

    // Staker struct
    struct Staker {
        uint256 _earned;
        uint256 _lastBlock;
        uint256 _power;
        uint256 _lastReleased;
    }

    // Events
    event Harvested(address staker, uint256 amount);

    // Addresses
    address public nftContract; // NFT Address
    address public tokenContract; // ERC20 token address

    // Rate governs how often you receive your token
    uint256 public rate;

    // mappings
    mapping(address => EnumerableSetUpgradeable.UintSet) private deposits;
    mapping(address => Staker) private stakers;
    address[] registeredStakers;
    mapping(uint256 => uint256) nftPower;

    uint256 public reservedPower;
    uint256 public allocatedPower;

    uint256 public releasedCorrection = 0;
    uint256 public reclaimable = 0;
    uint256 public reclaimableLastReleased = 0;

    uint256 startBlock = 0;

    bool __initialized = false;

    function initialize() public {
        require(__initialized == false, 'Already initialized');
        __initialized = true;
        __ReentrancyGuard_init_unchained();
        __Ownable_init_unchained();
        __Pausable_init_unchained();
        _pause();
    }

    function setNftContract(address _nftContract) public onlyOwner {
        nftContract = _nftContract;
    }

    function setTokenContract(address _tokenContract) public onlyOwner {
        tokenContract = _tokenContract;
    }

    // Pause & unpause contract
    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
        startBlock = block.number;
    }

    // Set a new rate. Store everyone's earnings first.
    function setRate(uint256 _rate) public onlyOwner() {
        rate = _rate;
    }

    // Get a list of deposits
    function depositsOf(address account) external view returns (uint256[] memory) {
        EnumerableSetUpgradeable.UintSet storage depositSet = deposits[account];
        uint256[] memory tokenIds = new uint256[] (depositSet.length());
        for (uint256 i; i < depositSet.length(); i++) {
            tokenIds[i] = depositSet.at(i);
        }
        return tokenIds;
    }

    // Owner: Harvest earnings
    function harvest() public nonReentrant {
        uint256 earned = earnings(msg.sender);
        require(earned > 0, 'NFTStake: No rewards');

        stakers[msg.sender]._earned = 0;
        stakers[msg.sender]._lastReleased = released();

        // Send rewards
        MintableToken(tokenContract).mint(msg.sender, earned);

        emit Harvested(msg.sender, earned);
    }

    /** VIEWS **/
    function earnings(address _staker) public view returns(uint256) {
        return stakers[_staker]._earned.add(
            earnedLastPeriod(stakers[_staker]._lastReleased, stakers[_staker]._power)
        );
    }

    function earnedLastPeriod(uint256 _lastReleased, uint256 _power) public view returns(uint256) {
        if(_power == 0) {
            return 0;
        }
        uint256 lastReleasedPeriod = released().sub(_lastReleased);
        if(lastReleasedPeriod > 0) {
            return lastReleasedPeriod
                .mul(_power)
                .div(reservedPower);
        }
        return 0;
    }

    function released() public view returns(uint256) {
        if(startBlock == 0) {
            return 0;
        }
        uint256 blocks = block.number - startBlock;
        return releasedCorrection.add(blocks.mul(rate));
    }

    function updatePower(address _owner, uint256 _power) internal {
        // Store earnings
        stakers[_owner]._earned = earnings(_owner);
        stakers[_owner]._lastReleased = released();

        if(allocatedPower <= reservedPower) {
            reclaimable = reclaimable.add(
                earnedLastPeriod(reclaimableLastReleased, reservedPower.sub(allocatedPower))
            );
            reclaimableLastReleased = released();
        }

        // Adjust pool power
        allocatedPower = allocatedPower.sub(stakers[_owner]._power).add(_power);
        uint256 shouldBeReserved = allocatedPower;
        if(shouldBeReserved > reservedPower) {
            reservedPower = allocatedPower;
        }
        stakers[_owner]._power = _power;
    }

    /** NFT transactions **/
    function deposit(uint256[] calldata tokenIds) external whenNotPaused {
        Staker memory staker = stakers[msg.sender];
        if(staker._lastBlock == 0) {
            stakers[msg.sender] = Staker(0, block.number, 0, released());
            registeredStakers.push(msg.sender);
        }

        uint256 power = staker._power;
        for (uint256 i; i < tokenIds.length; i++) {
            IERC721(nftContract).transferFrom(msg.sender,address(this),tokenIds[i]);
            deposits[msg.sender].add(tokenIds[i]);
            power += nftPower[tokenIds[i]];
        }
        updatePower(msg.sender, power);
    }

    // Withdrawal function
    function withdraw(uint256[] calldata tokenIds) external whenNotPaused nonReentrant {
        uint256 power = stakers[msg.sender]._power;
        for (uint256 i; i < tokenIds.length; i++) {
            require(deposits[msg.sender].contains(tokenIds[i]), "Staking: You are not token owner");
            power -= nftPower[tokenIds[i]];
            deposits[msg.sender].remove(tokenIds[i]);
            IERC721(nftContract).transferFrom(address(this), msg.sender,tokenIds[i]);
        }
        updatePower(msg.sender, power);
    }

    function setPower(uint256[] memory _ids, uint256[] memory _power) public onlyOwner {
        require(_ids.length == _power.length);
        for(uint256 i = 0;i < _ids.length; i++) {
            nftPower[_ids[i]] = _power[i];
        }
    }
}
