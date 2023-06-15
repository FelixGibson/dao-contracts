use core::array::ArrayTrait;
// @title VestingEscrow for claiming vested JDI tokens
// @author JediSwap
// @license MIT

use starknet::ContractAddress;

#[abi]
trait IERC20 {
    #[view]
    fn balance_of(account: ContractAddress) -> u256;
    #[external]
    fn transfer(recipient: ContractAddress, amount: u256) -> bool;
    #[external]
    fn transfer_from(sender: ContractAddress, recipient: ContractAddress, amount: u256) -> bool;
}

#[contract]
mod VestingEscrow {
    use starknet::get_block_timestamp;
    use starknet::get_caller_address;
    use starknet::get_contract_address;
    use starknet::ContractAddress;
    use starknet::contract_address_const;
    use zeroable::Zeroable;
    use traits::Into;
    use traits::TryInto;
    use array::ArrayTrait;
    use option::OptionTrait;
    use integer::u256_from_felt252;
    use super::IERC20Dispatcher;
    use super::IERC20DispatcherTrait;
    
    use jediswap_dao::utils::ownable::Ownable; 

    // Events

    #[event]
    fn Fund(recipient: ContractAddress, amount: u256) {}

    #[event]
    fn Claim(recipient: ContractAddress, claimed: u256) {}

    #[event]
    fn ToggleDisable(recipient: ContractAddress, disabled: bool) {}

    #[event]
    fn CommitOwnership(admin: ContractAddress) {}

    #[event]
    fn ApplyOwnership(admin: ContractAddress) {}

    struct Storage {
        _token: ContractAddress,
        _start_time: u256,
        _end_time: u256,
        _can_disable: bool,
        _owner: ContractAddress,
        _future_owner: ContractAddress,
        _fund_admins: LegacyMap::<ContractAddress, bool>,
        _fund_admins_enabled: bool,
        _initial_locked: LegacyMap::<ContractAddress, u256>,
        _total_claimed: LegacyMap::<ContractAddress, u256>,
        _initial_locked_supply: u256,
        _unallocated_supply: u256,
        _disabled_at: LegacyMap::<ContractAddress, u256>,
    }

    #[constructor]
    fn constructor(
        token: ContractAddress,
        start_time: u256,
        end_time: u256,
        can_disable: bool,
        owner: ContractAddress,
    ) {
        assert(!token.is_zero(), 'token is zero');
        assert(!owner.is_zero(), 'owner is zero');
        assert(start_time < end_time, 'start_time >= end_time');
        let current_time: felt252 = get_block_timestamp().into();
        assert(current_time.into() < start_time, 'start_time >= block.timestamp');

        _token::write(token);
        _start_time::write(start_time);
        _end_time::write(end_time);
        _can_disable::write(can_disable);
        _owner::write(owner);
    }

    // @notice Transfer vestable tokens into the contract
    // @dev Handled separate from `fund` to reduce transaction count when using funding admins
    // @param amount Number of tokens to transfer
    #[external]
    fn add_tokens(amount: u256) {
        assert(get_caller_address() == _owner::read(), 'not owner');

        IERC20Dispatcher {
            contract_address: _token::read()
        }.transfer_from(get_caller_address(), get_contract_address(), amount);

        _unallocated_supply::write(_unallocated_supply::read() + amount);
    }

    // @notice Vest tokens for multiple recipients
    // @param recipients List of addresses to fund
    // @param amounts Amount of vested tokens for each address
    #[external]
    fn fund(recipients: Array::<ContractAddress>, amounts: Array::<u256>) {
        assert(recipients.len() == amounts.len(), 'length mismatch');
        if get_caller_address() != _owner::read() {
            assert(_fund_admins_enabled::read(), 'not owner or fund admin');
            assert(_fund_admins::read(get_caller_address()), 'not owner or fund admin');
        }
        let mut total_amount: u256 = 0;
        let mut i = 0;
        loop {
            if i >= recipients.len() {
                break();
            }
            let recipient = recipients[i];
            let amount = amounts[i];
            assert(!(*recipient).is_zero(), 'recipient is zero');
            total_amount += *amount;
            _initial_locked::write(*recipient, _initial_locked::read(*recipient) + (*amount));
            i += 1;
            Fund(*recipient, *amount);
        };
        _unallocated_supply::write(_unallocated_supply::read() - total_amount);
        _initial_locked_supply::write(_initial_locked_supply::read() + total_amount);
    }

    // @notice Disable or re-enable a vested address's ability to claim tokens
    // @dev When disabled, the address is only unable to claim tokens which are still
    //      locked at the time of this call. It is not possible to block the claim
    //      of tokens which have already vested.
    // @param recipient Address to disable or enable
    #[external]
    fn toggle_disable(recipient: ContractAddress) {
        assert(get_caller_address() == _owner::read(), 'not owner');
        assert(_can_disable::read(), 'cannot disable');

        if _disabled_at::read(recipient) == u256_from_felt252(0) {
            let current_time: felt252 = get_block_timestamp().into();
            _disabled_at::write(recipient, current_time.into());
        } else {
            _disabled_at::write(recipient, u256_from_felt252(0));
        }
        ToggleDisable(recipient, _disabled_at::read(recipient) != u256_from_felt252(0));
    }

    // @notice Disable the ability to call `toggle_disable`
    #[external]
    fn disable_can_disable() {
        assert(get_caller_address() == _owner::read(), 'not owner');
        _can_disable::write(false);
    }

    // @notice Disable the funding admin accounts
    #[external]
    fn disable_fund_admins() {
        assert(get_caller_address() == _owner::read(), 'not owner');
        _fund_admins_enabled::write(false);
    }

    // @notice Get the total number of tokens which have vested, that are held by this contract
    // @return vested_supply
    #[view]
    fn vested_supply() -> u256 {
        _total_vested()
    }

    // @notice Get the total number of tokens which are still locked (have not yet vested)
    // @return locked_supply
    #[view]
    fn locked_supply() -> u256 {
        _initial_locked_supply::read() - _total_vested()
    }

    // @notice Get the number of tokens which have vested for a given address
    // @param recipient address to check
    // @return vested
    #[view]
    fn vested_of(recipient: ContractAddress) -> u256 {
        let current_time: felt252 = get_block_timestamp().into();
        _total_vested_of(recipient, current_time.into())
    }

    // @notice Get the number of unclaimed, vested tokens for a given address
    // @param recipient address to check
    // @return unclaimed number
    #[view]
    fn balance_of(recipient: ContractAddress) -> u256 {
        let current_time: felt252 = get_block_timestamp().into();
        let vested = _total_vested_of(recipient, current_time.into());
        let claimed = _total_claimed::read(recipient);
        if vested > claimed {
            return vested - claimed;
        }
        return 0;
    }

    // @notice Get the number of locked tokens for a given address
    // @param recipient address to check
    // @return locked_supply
    #[view]
    fn locked_of(recipient: ContractAddress) -> u256 {
        _initial_locked::read(recipient) - _total_vested_of_only_recipient(recipient)
    }

    // @notice Claim tokens which have vested
    #[external]
    fn claim() {
        let sender = get_caller_address();
        let mut time = _disabled_at::read(sender);
        if time == 0 {
            let current_time: felt252 = get_block_timestamp().into();
            time = current_time.into();
        }
        let claimable = _total_vested_of(sender, time) - _total_claimed::read(sender);
        _total_claimed::write(sender, _total_claimed::read(sender) + claimable);
        IERC20Dispatcher {
            contract_address: _token::read()
        }.transfer(sender, claimable);

        Claim(sender, claimable);
    }

    // @notice Change ownership to `future_owner`
    // @dev Only owner can change. Needs to be accepted by future_owner using apply_transfer_ownership
    // @param future_owner Address of new owner
    #[external]
    fn commit_transfer_ownership(future_owner: ContractAddress) -> bool {
        assert(get_caller_address() == _owner::read(), 'not owner');
        _future_owner::write(future_owner);
        CommitOwnership(future_owner);
        true
    }

    // @notice Change ownership to future_owner
    // @dev Only owner can accept. Needs to be initiated via commit_transfer_ownership
    #[external]
    fn apply_transfer_ownership() -> bool {
        assert(get_caller_address() == _future_owner::read(), 'not future owner');
        _owner::write(_future_owner::read());
        _future_owner::write(contract_address_const::<0>());
        ApplyOwnership(_owner::read());
        true
    }

    #[internal]
    fn _total_vested_of_only_recipient(recipient: ContractAddress) -> u256 {
        let current_time: felt252 = get_block_timestamp().into();
        _total_vested_of(recipient, current_time.into())
    }

    #[internal]
    fn _total_vested_of(recipient: ContractAddress, time: u256) -> u256 {
        let start = _start_time::read();
        let end = _end_time::read();
        let locked = _initial_locked::read(recipient);
        if time < start {
            return 0;
        }
        if time >= end {
            return locked;
        }
        return locked * (time - start) / (end - start);
    }

    #[internal]
    fn _total_vested() -> u256 {
        let current_time: felt252 = get_block_timestamp().into();
        let start = _start_time::read();
        let end = _end_time::read();
        let locked = _initial_locked_supply::read();
        if current_time.into() < start {
            return 0;
        }
        if current_time.into() >= end {
            return locked;
        }
        return locked * (current_time.into() - start) / (end - start);
    }


}
