// @title JediSwap DAO Minter
// @author JediSwap
// @license MIT

use starknet::ContractAddress;

#[abi]
trait ILiquidityGauge {
    fn integrate_fraction(user: ContractAddress) -> u256;
    fn user_checkpoint(user: ContractAddress);
}

#[abi]
trait IERC20JDI {
    fn mint(recipient: ContractAddress, amount: u256) -> bool;
}

#[abi]
trait IGaugeController {
    fn gauge_types(gauge: ContractAddress) -> u256;
}

#[contract]
mod Minter {
    use starknet::ContractAddress;
    use zeroable::Zeroable;
    use starknet::get_caller_address;
    use starknet::get_block_timestamp;
    use starknet::contract_address_const;
    use traits::Into;
    use traits::TryInto;
    use array::ArrayTrait;
    use option::OptionTrait;
    use integer::u256_from_felt252;
    use array::SpanTrait;
    use super::ILiquidityGaugeDispatcher;
    use super::ILiquidityGaugeDispatcherTrait;
    use super::IERC20JDIDispatcher;
    use super::IERC20JDIDispatcherTrait;
    use super::IGaugeControllerDispatcher;
    use super::IGaugeControllerDispatcherTrait;

    struct Storage {
        // @dev JDI token address
        _token: ContractAddress,
        // @dev Gauge controller address
        _controller: ContractAddress,
        // @dev user, gauge -> value
        _minted: LegacyMap::<(ContractAddress, ContractAddress), u256>,
        // @dev minter, user -> true if allowed to mint
        _allowed_to_mint_for: LegacyMap::<(ContractAddress, ContractAddress), bool>,
        // @dev reentrancy guard
        _reentrancy_locked: felt252,
    }

    // @notice An event emitted whenever _mint_for() is called.
    #[event]
    fn Minted(recipient: ContractAddress, gauge: ContractAddress, minted: u256) {}

    // @notice Contract constructor
    // @param token JDI token address
    // @param controller Gauge controller address
    #[constructor]
    fn constructor(token: ContractAddress, controller: ContractAddress) {
        _token::write(token);
        _controller::write(controller);
    }

    // @notice Token Address
    // @return address
    #[view]
    fn token() -> ContractAddress {
        _token::read()
    }

    // @notice Gauge controller Address
    // @return address
    #[view]
    fn controller() -> ContractAddress {
        _controller::read()
    }

    // @notice Tokens Minted for user in gauge
    // @param user User for which to check
    // @param gauge Gauge in which tokens are minted
    // @return amount of tokens minted
    #[view]
    fn minted(user: ContractAddress, gauge: ContractAddress) -> u256 {
        _minted::read((user, gauge))
    }

    // @notice Check if minter_user is allowed to mint for for_user
    // @param minter_user User which is allowed to mint
    // @param for_user User for which we are checking
    // @return can_mint true/false (1/0)
    #[view]
    fn allowed_to_mint_for(minter_user: ContractAddress, for_user: ContractAddress) -> bool {
        _allowed_to_mint_for::read((minter_user, for_user))
    }

    // @notice Mint everything which belongs to `caller` and send to them
    // @param gauge `LiquidityGauge` address to get mintable amount from
    #[external]
    fn mint(gauge: ContractAddress) {
        _check_and_lock_reentrancy();
        let caller = get_caller_address();
        _mint_for(gauge, caller);
        _unlock_reentrancy();
    }

    // @notice Mint everything which belongs to `caller` across multiple gauges
    // @param gauges `LiquidityGauge` addresss to get mintable amount from
    #[external]
    fn mint_many(gauges: Array::<ContractAddress>) {
        _check_and_lock_reentrancy();
        let caller = get_caller_address();
        _mint_for_many(gauges, caller);
        _unlock_reentrancy();
    }

    // @notice Mint tokens for `for_user`
    // @dev Only possible when `caller` has been approved via `toggle_approve_mint`
    // @param gauge `LiquidityGauge` address to get mintable amount from
    // @param for_user Address to mint to
    #[external]
    fn mint_for(gauge: ContractAddress, for_user: ContractAddress) {
        _check_and_lock_reentrancy();
        let caller = get_caller_address();
        let allowed_to_mint_for = _allowed_to_mint_for::read((caller, for_user));
        assert(allowed_to_mint_for, 'Not allow mint for');
        _mint_for(gauge, for_user);
        _unlock_reentrancy();
    }

    // @notice allow `minter_user` to mint for `caller`
    // @param minter_user Address to toggle permission for
    #[external]
    fn toggle_approve_mint(minter_user: ContractAddress) {
        let caller = get_caller_address();
        let allowed_to_mint_for = _allowed_to_mint_for::read((minter_user, caller));
        if allowed_to_mint_for {
            _allowed_to_mint_for::write((minter_user, caller), false);
        } else {
            _allowed_to_mint_for::write((minter_user, caller), true);
        }
    }

    fn _mint_for_many(gauges: Array::<ContractAddress>, for_user: ContractAddress) {
        let mut gauges_span = gauges.span();
        loop {
            match gauges_span.pop_front() {
                Option::Some(v) => {
                    _mint_for(*v, for_user);
                },
                Option::None(_) => {
                    break ();
                },
            };
        };
    }

    fn _mint_for(gauge: ContractAddress, for_user: ContractAddress) {
        assert(IGaugeControllerDispatcher {
            contract_address: _controller::read()
        }.gauge_types(gauge) > 0, 'gauge is not added');  // differ from Curve which is >= 0. why since u256 cannot be negative?
        ILiquidityGaugeDispatcher {
            contract_address: gauge
        }.user_checkpoint(for_user);
        let total_mint = ILiquidityGaugeDispatcher {
            contract_address: gauge
        }.integrate_fraction(for_user);
        let to_mint = total_mint - _minted::read((for_user, gauge));
        if to_mint > 0 {
            _minted::write((for_user, gauge), total_mint);
            IERC20JDIDispatcher {
                contract_address: _token::read()
            }.mint(for_user, to_mint);
            Minted(for_user, gauge, to_mint);
        }
    }

    fn _check_and_lock_reentrancy() {
        let reentrancy_locked = _reentrancy_locked::read();
        assert(reentrancy_locked == 0, 'Reentrancy detected');
        _reentrancy_locked::write(1);

    }

    fn _unlock_reentrancy() {
        let reentrancy_locked = _reentrancy_locked::read();
        assert(reentrancy_locked == 1, 'Reentrancy lock not set');
        _reentrancy_locked::write(0);
    }

}