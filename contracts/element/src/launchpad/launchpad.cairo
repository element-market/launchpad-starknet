// SPDX-License-Identifier: MIT

#[starknet::contract]
mod Launchpad {
    use starknet::{
        ContractAddress, ClassHash, get_caller_address, call_contract_syscall, replace_class_syscall
    };
    use zeroable::Zeroable;
    use array::ArrayTrait;
    use option::OptionTrait;
    use traits::{Into, TryInto};
    use element::launchpad::interface::{ILaunchpad, IOwnable, IUpgradeable};
    use element::utils::{selectors, unwrap_and_cast::UnwrapAndCast};

    #[storage]
    struct Storage {
        _mint_target: ContractAddress,
        _reentrancy_guard: bool,
        _owner: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        OwnershipTransferred: OwnershipTransferred,
        Upgraded: Upgraded,
    }

    #[derive(Drop, starknet::Event)]
    struct OwnershipTransferred {
        previous_owner: ContractAddress,
        new_owner: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct Upgraded {
        class_hash: ClassHash
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self._transfer_ownership(owner);
    }

    #[external(v0)]
    impl LaunchpadImpl of ILaunchpad<ContractState> {
        fn mint(ref self: ContractState, signature0: felt252, signature1: felt252) {
            self._reentrancy_enter();

            let target = self._mint_target.read();
            if target.is_zero() {
                panic_with_felt252('target cannot be zero');
            }

            let caller: felt252 = get_caller_address().into();
            let args: Array<felt252> = array![caller, signature0, signature1];
            let magic: felt252 = call_contract_syscall(target, selectors::mint, args.span())
                .unwrap_and_cast();
            assert(magic == selectors::mint, 'mint failed');

            self._reentrancy_exit();
        }

        fn set_mint_target(ref self: ContractState, target: ContractAddress) {
            self._assert_only_owner();
            self._mint_target.write(target);
        }

        fn get_mint_target(self: @ContractState) -> ContractAddress {
            self._mint_target.read()
        }
    }

    #[external(v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, impl_hash: ClassHash) {
            self._assert_only_owner();
            if impl_hash.is_zero() {
                panic_with_felt252('class hash cannot be zero');
            }
            replace_class_syscall(impl_hash).unwrap_syscall();
            self.emit(Upgraded { class_hash: impl_hash });
        }
    }

    #[external(v0)]
    impl OwnableImpl of IOwnable<ContractState> {
        fn owner(self: @ContractState) -> ContractAddress {
            self._owner.read()
        }

        fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            assert(!new_owner.is_zero(), 'new owner is the zero address');
            self._assert_only_owner();
            self._transfer_ownership(new_owner);
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        #[inline(always)]
        fn _reentrancy_enter(ref self: ContractState) {
            if self._reentrancy_guard.read() {
                panic_with_felt252('reentrant call');
            }
            self._reentrancy_guard.write(true);
        }

        #[inline(always)]
        fn _reentrancy_exit(ref self: ContractState) {
            self._reentrancy_guard.write(false);
        }

        #[inline(always)]
        fn _assert_only_owner(ref self: ContractState) {
            let caller: ContractAddress = get_caller_address();
            if caller.is_zero() {
                panic_with_felt252('caller is the zero address');
            }
            assert(caller == self._owner.read(), 'caller is not the owner');
        }

        #[inline(always)]
        fn _transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            let previous_owner: ContractAddress = self._owner.read();
            self._owner.write(new_owner);
            self
                .emit(
                    OwnershipTransferred { previous_owner: previous_owner, new_owner: new_owner }
                );
        }
    }
}
