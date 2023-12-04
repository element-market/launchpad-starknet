// SPDX-License-Identifier: MIT

use starknet::{ContractAddress, ClassHash};

#[derive(Copy, Drop, Serde, starknet::Store)]
struct BaseUri {
    uri0: felt252,
    uri1: felt252,
    uri2: felt252,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct MintConfig {
    signer: felt252,
    minter: ContractAddress,
    start_time: u64,
    end_time: u64,
}

#[starknet::interface]
trait IMint<TState> {
    fn mint(
        ref self: TState, to: ContractAddress, signature0: felt252, signature1: felt252
    ) -> felt252;
    fn set_base_uri(ref self: TState, base_uri: Span<BaseUri>);
    fn set_mint_config(ref self: TState, config: MintConfig);
    fn get_mint_config(self: @TState) -> MintConfig;
    fn is_minted(self: @TState, account: ContractAddress) -> bool;
    fn total_supply(self: @TState) -> u256;
    fn max_supply(self: @TState) -> u256;
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
