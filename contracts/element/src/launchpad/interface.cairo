// SPDX-License-Identifier: MIT

use starknet::{ContractAddress, ClassHash};

#[starknet::interface]
trait ILaunchpad<TState> {
    fn mint(ref self: TState, signature0: felt252, signature1: felt252);
    fn set_mint_target(ref self: TState, target: ContractAddress);
    fn get_mint_target(self: @TState) -> ContractAddress;
}

#[starknet::interface]
trait IUpgradeable<TState> {
    fn upgrade(ref self: TState, impl_hash: ClassHash);
}

#[starknet::interface]
trait IOwnable<TState> {
    fn owner(self: @TState) -> ContractAddress;
    fn transfer_ownership(ref self: TState, new_owner: ContractAddress);
}
