// SPDX-License-Identifier: GPL-3.0-only
// This is a PoC to use the staking precompile wrapper as a Solidity developer.
pragma solidity >=0.8.0;

import "./StakingInterface.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract DelegationDAO is AccessControl {

    using SafeMath for uint256;
    
    // Role definition for contract members
    bytes32 public constant MEMBER = keccak256("MEMBER");

    // Possible states for the DAO to be in:
    // COLLECTING: the DAO is collecting funds before creating a delegation once the minimum delegation stake has been reached
    // STAKING: the DAO has an active delegation
    // REVOKING: the DAO has scheduled a delegation revoke
    // REVOKED: the scheduled revoke has been executed
    enum daoState{ COLLECTING, STAKING, REVOKING, REVOKED }

    // Current state that the DAO is in
    daoState public currentState; 

    // Member stakes (doesnt include rewards, represents member shares)
    mapping(address => uint256) public memberStakes;
    
    // Total Staking Pool (doesnt include rewards, represents total shares)
    uint256 public totalStake;

    // The ParachainStaking wrapper at the known pre-compile address. This will be used to make
    // all calls to the underlying staking solution
    ParachainStaking public staking;
    
    // Minimum Delegation Amount
    uint256 public constant minDelegationStk = 5 ether;
    
    // Moonbeam Staking Precompile address
    address public constant stakingPrecompileAddress = 0x0000000000000000000000000000000000000800;

    // The collator that this DAO is currently nominating
    address public target;

    // Event for a member deposit
    event deposit(address indexed _from, uint _value);

    // Event for a member withdrawal
    event withdrawal(address indexed _from, address indexed _to, uint _value);

    // Initialize a new DelegationDao dedicated to delegating to the given collator target.
    constructor(address _target, address admin) {
        
        //Sets the collator that this DAO nominating
        target = _target;
        
        // Initializes Moonbeam's parachain staking precompile
        staking = ParachainStaking(stakingPrecompileAddress);
        
        //Initializes Roles
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setupRole(MEMBER, admin);

        //Initialize the DAO state
        currentState = daoState.COLLECTING;
        
    }

    // Grant a user the role of admin
    function grant_admin(address newAdmin)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
        onlyRole(MEMBER)
    {
        grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        grantRole(MEMBER, newAdmin);
    }

    // Grant a user membership
    function grant_member(address newMember)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        grantRole(MEMBER, newMember);
    }

    // Revoke a user membership
    function remove_member(address payable exMember)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        revokeRole(MEMBER, exMember);
    }

    // Increase member stake via a payable function and automatically stake the added amount if possible
    function add_stake() external payable onlyRole(MEMBER) {
        if (currentState == daoState.STAKING ) {
            // Sanity check
            if(!staking.is_delegator(address(this))){
                 revert("The DAO is in an inconsistent state :(......... womp womp womp");
            }
            memberStakes[msg.sender] = memberStakes[msg.sender].add(msg.value);
            totalStake = totalStake.add(msg.value);
            emit deposit(msg.sender, msg.value);
            staking.delegator_bond_more(target, msg.value);
        }
        else if  (currentState == daoState.COLLECTING ){
            memberStakes[msg.sender] = memberStakes[msg.sender].add(msg.value);
            totalStake = totalStake.add(msg.value);
            emit deposit(msg.sender, msg.value);
            if(totalStake < minDelegationStk){
                return;
            } else {
                //initialiate the delegation and change the state          
                staking.delegate(target, address(this).balance, staking.candidate_delegation_count(target), staking.delegator_delegation_count(address(this)));
                currentState = daoState.STAKING;
            }
        }
        else {
            revert("The DAO is not accepting new stakes in the current state.");
        }
    }

    // Function for a user to withdraw their stake
    function withdraw(address payable account) public onlyRole(MEMBER) {
        require(currentState != daoState.STAKING, "The DAO is not in the correct state to withdraw.");
        if (currentState == daoState.REVOKING) {
            bool result = execute_revoke();
            require(result, "Schedule revoke delay is not finished yet.");
        }
        if (currentState == daoState.REVOKED || currentState == daoState.COLLECTING) {
            //Sanity checks
            if(staking.is_delegator(address(this))){
                 revert("The DAO is in an inconsistent state.");
            }
            require(totalStake!=0, "Cannot divide by zero.");
            //Calculate the withdrawal amount including staking rewards
            uint amount = address(this)
                .balance
                .mul(memberStakes[msg.sender])
                .div(totalStake);
            require(check_free_balance() >= amount, "Not enough free balance for withdrawal.");
            Address.sendValue(account, amount);
            totalStake = totalStake.sub(memberStakes[msg.sender]);
            memberStakes[msg.sender] = 0;
            emit withdrawal(msg.sender, account, amount);
        }
    }

    // Schedule revoke, admin only
    function schedule_revoke() public onlyRole(DEFAULT_ADMIN_ROLE){
        require(currentState == daoState.STAKING, "The DAO is not in the correct state to schedule a revoke.");
        staking.schedule_revoke_delegation(target);
        currentState = daoState.REVOKING;
    }
    
    // Try to execute the revoke, returns true if it succeeds, false if it doesn't
    function execute_revoke() internal onlyRole(MEMBER) returns(bool) {
        require(currentState == daoState.REVOKING, "The DAO is not in the correct state to execute a revoke.");
        staking.execute_delegation_request(address(this), target);
        if (staking.is_delegator(address(this))){
            return false;
        } else {
            currentState = daoState.REVOKED;
            return true;
        }
    }

    // Check how much free balance the DAO currently has. It should be the staking rewards if the DAO state is anything other than REVOKED or COLLECTING. 
    function check_free_balance() public view onlyRole(MEMBER) returns(uint256) {
        return address(this).balance;
    }
    
    // Change the collator target, admin only
    function change_target(address newCollator) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(currentState == daoState.REVOKED || currentState == daoState.COLLECTING, "The DAO is not in the correct state to change staking target.");
        target = newCollator;
    }

    // Reset the DAO state back to COLLECTING, admin only
    function reset_dao() public onlyRole(DEFAULT_ADMIN_ROLE) {
        currentState = daoState.COLLECTING;
    }


}