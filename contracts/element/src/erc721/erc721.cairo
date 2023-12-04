// SPDX-License-Identifier: MIT

const MAX_SUPPLY: u128 = 120000;

#[starknet::contract]
mod ERC721 {
    use starknet::{
        ContractAddress, ClassHash, get_block_timestamp, get_caller_address, get_contract_address,
        replace_class_syscall
    };
    use zeroable::Zeroable;
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use traits::{Into, TryInto};
    use element::erc721::erc721_interface::{
        IERC721, IERC721CamelOnly, IERC721Metadata, IERC721MetadataCamelOnly, ISRC5, ISRC5Camel
    };
    use element::erc721::mint_interface::{BaseUri, MintConfig, IMint, IUpgradeable, IOwnable};
    use element::utils::{
        call, constants, selectors, serde::SerializedAppend, unwrap_and_cast::UnwrapAndCast
    };

    #[storage]
    struct Storage {
        ERC721_name: felt252,
        ERC721_symbol: felt252,
        ERC721_owners: LegacyMap<u256, ContractAddress>,
        ERC721_balances: LegacyMap<ContractAddress, u128>,
        ERC721_token_approvals: LegacyMap<u256, ContractAddress>,
        ERC721_operator_approvals: LegacyMap<(ContractAddress, ContractAddress), bool>,
        Mint_base_uri: LegacyMap<u128, BaseUri>,
        Mint_config: MintConfig,
        Mint_total_supply: u128,
        Mint_is_minted: LegacyMap<ContractAddress, bool>,
        Ownable_owner: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Transfer: Transfer,
        Approval: Approval,
        ApprovalForAll: ApprovalForAll,
        OwnershipTransferred: OwnershipTransferred,
        Upgraded: Upgraded,
    }

    #[derive(Drop, starknet::Event)]
    struct Transfer {
        #[key]
        from: ContractAddress,
        #[key]
        to: ContractAddress,
        #[key]
        token_id: u256
    }

    #[derive(Drop, starknet::Event)]
    struct Approval {
        #[key]
        owner: ContractAddress,
        #[key]
        approved: ContractAddress,
        #[key]
        token_id: u256
    }

    #[derive(Drop, starknet::Event)]
    struct ApprovalForAll {
        #[key]
        owner: ContractAddress,
        #[key]
        operator: ContractAddress,
        approved: bool
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

    mod Errors {
        const INVALID_TOKEN_ID: felt252 = 'ERC721: invalid token ID';
        const INVALID_ACCOUNT: felt252 = 'ERC721: invalid account';
        const UNAUTHORIZED: felt252 = 'ERC721: unauthorized caller';
        const APPROVAL_TO_OWNER: felt252 = 'ERC721: approval to owner';
        const SELF_APPROVAL: felt252 = 'ERC721: self approval';
        const INVALID_RECEIVER: felt252 = 'ERC721: invalid receiver';
        const ALREADY_MINTED: felt252 = 'ERC721: token already minted';
        const WRONG_SENDER: felt252 = 'ERC721: wrong sender';
        const SAFE_MINT_FAILED: felt252 = 'ERC721: safe mint failed';
        const SAFE_TRANSFER_FAILED: felt252 = 'ERC721: safe transfer failed';
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, name: felt252, symbol: felt252, owner: ContractAddress
    ) {
        self.ERC721_name.write(name);
        self.ERC721_symbol.write(symbol);
        self._transfer_ownership(owner);
    }

    //
    // External
    //

    #[external(v0)]
    impl SRC5Impl of ISRC5<ContractState> {
        fn supports_interface(self: @ContractState, interface_id: felt252) -> bool {
            self._supports_interface(interface_id)
        }
    }

    #[external(v0)]
    impl SRC5CamelImpl of ISRC5Camel<ContractState> {
        fn supportsInterface(self: @ContractState, interfaceId: felt252) -> bool {
            self._supports_interface(interfaceId)
        }
    }

    #[external(v0)]
    impl ERC721MetadataImpl of IERC721Metadata<ContractState> {
        fn name(self: @ContractState) -> felt252 {
            self.ERC721_name.read()
        }

        fn symbol(self: @ContractState) -> felt252 {
            self.ERC721_symbol.read()
        }

        fn token_uri(self: @ContractState, token_id: u256) -> Span<felt252> {
            self._token_uri(token_id)
        }
    }

    #[external(v0)]
    impl ERC721MetadataCamelOnlyImpl of IERC721MetadataCamelOnly<ContractState> {
        fn tokenURI(self: @ContractState, tokenId: u256) -> Span<felt252> {
            self._token_uri(tokenId)
        }
    }

    #[external(v0)]
    impl ERC721Impl of IERC721<ContractState> {
        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            assert(!account.is_zero(), Errors::INVALID_ACCOUNT);
            self.ERC721_balances.read(account).into()
        }

        fn owner_of(self: @ContractState, token_id: u256) -> ContractAddress {
            self._owner_of(token_id)
        }

        fn get_approved(self: @ContractState, token_id: u256) -> ContractAddress {
            assert(self._exists(token_id), Errors::INVALID_TOKEN_ID);
            self.ERC721_token_approvals.read(token_id)
        }

        fn is_approved_for_all(
            self: @ContractState, owner: ContractAddress, operator: ContractAddress
        ) -> bool {
            self.ERC721_operator_approvals.read((owner, operator))
        }

        fn approve(ref self: ContractState, to: ContractAddress, token_id: u256) {
            let owner = self._owner_of(token_id);

            let caller = get_caller_address();
            assert(
                owner == caller || ERC721Impl::is_approved_for_all(@self, owner, caller),
                Errors::UNAUTHORIZED
            );
            self._approve(to, token_id);
        }

        fn set_approval_for_all(
            ref self: ContractState, operator: ContractAddress, approved: bool
        ) {
            self._set_approval_for_all(get_caller_address(), operator, approved)
        }

        fn transfer_from(
            ref self: ContractState, from: ContractAddress, to: ContractAddress, token_id: u256
        ) {
            assert(
                self._is_approved_or_owner(get_caller_address(), token_id), Errors::UNAUTHORIZED
            );
            self._transfer(from, to, token_id);
        }

        fn safe_transfer_from(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            token_id: u256,
            data: Span<felt252>
        ) {
            assert(
                self._is_approved_or_owner(get_caller_address(), token_id), Errors::UNAUTHORIZED
            );
            self._safe_transfer(from, to, token_id, data);
        }
    }

    #[external(v0)]
    impl ERC721CamelOnlyImpl of IERC721CamelOnly<ContractState> {
        fn balanceOf(self: @ContractState, account: ContractAddress) -> u256 {
            ERC721Impl::balance_of(self, account)
        }

        fn ownerOf(self: @ContractState, tokenId: u256) -> ContractAddress {
            ERC721Impl::owner_of(self, tokenId)
        }

        fn getApproved(self: @ContractState, tokenId: u256) -> ContractAddress {
            ERC721Impl::get_approved(self, tokenId)
        }

        fn isApprovedForAll(
            self: @ContractState, owner: ContractAddress, operator: ContractAddress
        ) -> bool {
            ERC721Impl::is_approved_for_all(self, owner, operator)
        }

        fn setApprovalForAll(ref self: ContractState, operator: ContractAddress, approved: bool) {
            ERC721Impl::set_approval_for_all(ref self, operator, approved)
        }

        fn transferFrom(
            ref self: ContractState, from: ContractAddress, to: ContractAddress, tokenId: u256
        ) {
            ERC721Impl::transfer_from(ref self, from, to, tokenId)
        }

        fn safeTransferFrom(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            tokenId: u256,
            data: Span<felt252>
        ) {
            ERC721Impl::safe_transfer_from(ref self, from, to, tokenId, data)
        }
    }

    #[external(v0)]
    impl MintImpl of IMint<ContractState> {
        fn mint(
            ref self: ContractState, to: ContractAddress, signature0: felt252, signature1: felt252
        ) -> felt252 {
            let config = self.Mint_config.read();
            if config.minter.is_zero() {
                panic_with_felt252('minter is unset');
            }
            assert(get_caller_address() == config.minter, 'the caller is not allowed');

            let now = get_block_timestamp();
            assert(now >= config.start_time, 'not started');
            assert(now < config.end_time, 'it\'s over');

            if config.signer == 0 {
                panic_with_felt252('signer is unset');
            }
            let hash = pedersen(to.into(), get_contract_address().into());
            let validate = ecdsa::check_ecdsa_signature(
                hash, config.signer, signature0, signature1
            );
            assert(validate, 'invalid signature');

            if self.Mint_is_minted.read(to) {
                panic_with_felt252('already purchased');
            }
            self.Mint_is_minted.write(to, true);

            let total_supply = self.Mint_total_supply.read();
            assert(total_supply < super::MAX_SUPPLY, 'sold out');

            let token_id: u128 = total_supply + 1;
            self.Mint_total_supply.write(token_id);

            self._mint(to, token_id.into());
            selectors::mint
        }

        fn set_base_uri(ref self: ContractState, base_uri: Span<BaseUri>) {
            self._assert_only_owner();
            self._set_base_uri(base_uri);
        }

        fn set_mint_config(ref self: ContractState, config: MintConfig) {
            self._assert_only_owner();
            self.Mint_config.write(config);
        }

        fn get_mint_config(self: @ContractState) -> MintConfig {
            self.Mint_config.read()
        }

        fn is_minted(self: @ContractState, account: ContractAddress) -> bool {
            self.Mint_is_minted.read(account)
        }

        fn total_supply(self: @ContractState) -> u256 {
            self.Mint_total_supply.read().into()
        }

        fn max_supply(self: @ContractState) -> u256 {
            super::MAX_SUPPLY.into()
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
            self.Ownable_owner.read()
        }

        fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            assert(!new_owner.is_zero(), 'new owner is the zero address');
            self._assert_only_owner();
            self._transfer_ownership(new_owner);
        }
    }

    //
    // Internal
    //

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _owner_of(self: @ContractState, token_id: u256) -> ContractAddress {
            let owner = self.ERC721_owners.read(token_id);
            match owner.is_zero() {
                bool::False(()) => owner,
                bool::True(()) => panic_with_felt252(Errors::INVALID_TOKEN_ID)
            }
        }

        fn _exists(self: @ContractState, token_id: u256) -> bool {
            !self.ERC721_owners.read(token_id).is_zero()
        }

        fn _is_approved_or_owner(
            self: @ContractState, spender: ContractAddress, token_id: u256
        ) -> bool {
            let owner = self._owner_of(token_id);
            let is_approved_for_all = ERC721Impl::is_approved_for_all(self, owner, spender);
            owner == spender
                || is_approved_for_all
                || spender == ERC721Impl::get_approved(self, token_id)
        }

        fn _approve(ref self: ContractState, to: ContractAddress, token_id: u256) {
            let owner = self._owner_of(token_id);
            assert(owner != to, Errors::APPROVAL_TO_OWNER);

            self.ERC721_token_approvals.write(token_id, to);
            self.emit(Approval { owner, approved: to, token_id });
        }

        fn _set_approval_for_all(
            ref self: ContractState,
            owner: ContractAddress,
            operator: ContractAddress,
            approved: bool
        ) {
            assert(owner != operator, Errors::SELF_APPROVAL);
            self.ERC721_operator_approvals.write((owner, operator), approved);
            self.emit(ApprovalForAll { owner, operator, approved });
        }

        fn _mint(ref self: ContractState, to: ContractAddress, token_id: u256) {
            assert(!to.is_zero(), Errors::INVALID_RECEIVER);
            assert(!self._exists(token_id), Errors::ALREADY_MINTED);

            self.ERC721_balances.write(to, self.ERC721_balances.read(to) + 1);
            self.ERC721_owners.write(token_id, to);

            self.emit(Transfer { from: Zeroable::zero(), to, token_id });
        }

        fn _transfer(
            ref self: ContractState, from: ContractAddress, to: ContractAddress, token_id: u256
        ) {
            assert(!to.is_zero(), Errors::INVALID_RECEIVER);
            let owner = self._owner_of(token_id);
            assert(from == owner, Errors::WRONG_SENDER);

            // Implicit clear approvals, no need to emit an event
            self.ERC721_token_approvals.write(token_id, Zeroable::zero());

            self.ERC721_balances.write(from, self.ERC721_balances.read(from) - 1);
            self.ERC721_balances.write(to, self.ERC721_balances.read(to) + 1);
            self.ERC721_owners.write(token_id, to);

            self.emit(Transfer { from, to, token_id });
        }

        fn _burn(ref self: ContractState, token_id: u256) {
            let owner = self._owner_of(token_id);

            // Implicit clear approvals, no need to emit an event
            self.ERC721_token_approvals.write(token_id, Zeroable::zero());

            self.ERC721_balances.write(owner, self.ERC721_balances.read(owner) - 1);
            self.ERC721_owners.write(token_id, Zeroable::zero());

            self.emit(Transfer { from: owner, to: Zeroable::zero(), token_id });
        }

        fn _safe_mint(
            ref self: ContractState, to: ContractAddress, token_id: u256, data: Span<felt252>
        ) {
            self._mint(to, token_id);
            assert(
                _check_on_erc721_received(Zeroable::zero(), to, token_id, data),
                Errors::SAFE_MINT_FAILED
            );
        }

        fn _safe_transfer(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            token_id: u256,
            data: Span<felt252>
        ) {
            self._transfer(from, to, token_id);
            assert(
                _check_on_erc721_received(from, to, token_id, data), Errors::SAFE_TRANSFER_FAILED
            );
        }

        fn _supports_interface(self: @ContractState, interface_id: felt252) -> bool {
            if interface_id == constants::IERC165_ID {
                true
            } else if interface_id == constants::IERC165_ID_OLD {
                true
            } else if interface_id == constants::IERC721_ID {
                true
            } else if interface_id == constants::IERC721_ID_OLD {
                true
            } else if interface_id == constants::IERC721_METADATA_ID {
                true
            } else if interface_id == constants::IERC721_METADATA_ID_OLD {
                true
            } else {
                false
            }
        }

        fn _assert_only_owner(ref self: ContractState) {
            let caller: ContractAddress = get_caller_address();
            if caller.is_zero() {
                panic_with_felt252('caller is the zero address');
            }
            assert(caller == self.Ownable_owner.read(), 'caller is not the owner');
        }

        fn _transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            let previous_owner: ContractAddress = self.Ownable_owner.read();
            self.Ownable_owner.write(new_owner);
            self
                .emit(
                    OwnershipTransferred { previous_owner: previous_owner, new_owner: new_owner }
                );
        }

        fn _set_base_uri(ref self: ContractState, base_uri: Span<BaseUri>) {
            let length: u32 = base_uri.len();
            let mut i: u32 = 0;
            loop {
                if i == length {
                    break;
                }
                self.Mint_base_uri.write(i.into(), *base_uri.at(i));
                i += 1_u32;
            };
        }

        fn _token_uri(self: @ContractState, token_id: u256) -> Span<felt252> {
            assert(self._exists(token_id), Errors::INVALID_TOKEN_ID);

            let id: u128 = token_id.try_into().unwrap();
            let uri_index: u128 = (id - 1) / 20000;
            let base_uri = self.Mint_base_uri.read(uri_index);
            if base_uri.uri0 == 0 {
                panic_with_felt252('base_uri is unset');
            }

            // convert token_id to shortString
            let mut value: u128 = id;
            let mut uri3: felt252 = 0;
            let mut multiplier: felt252 = 1;
            loop {
                if value == 0 {
                    break;
                }
                let ascii: felt252 = (value % 10).into() + 48;
                uri3 = ascii * multiplier + uri3;
                multiplier *= 0x100;
                value /= 10;
            };

            // append '.json'
            uri3 = uri3 * 0x10000000000 + 0x2e6a736f6e;

            array![base_uri.uri0, base_uri.uri1, base_uri.uri2, uri3].span()
        }
    }

    fn _check_on_erc721_received(
        from: ContractAddress, to: ContractAddress, token_id: u256, data: Span<felt252>
    ) -> bool {
        if _check_supports_interface(to, constants::IERC721_RECEIVER_ID) {
            constants::IERC721_RECEIVER_ID == _call_on_erc721_received(from, to, token_id, data)
        } else if _check_supports_interface(to, constants::IERC721_RECEIVER_ID_OLD) {
            constants::IERC721_RECEIVER_ID_OLD == _call_on_erc721_received(from, to, token_id, data)
        } else if _check_supports_interface(to, constants::IACCOUNT_ID) {
            true
        } else if _check_supports_interface(to, constants::IACCOUNT_ID_OLD_1) {
            true
        } else if _check_supports_interface(to, constants::IACCOUNT_ID_OLD_2) {
            true
        } else if _check_supports_interface(to, constants::IACCOUNT_ID_OLD_3) {
            true
        } else {
            false
        }
    }

    fn _check_supports_interface(to: ContractAddress, interface_id: felt252) -> bool {
        call::try_selector_with_fallback(
            to,
            selectors::supports_interface,
            selectors::supportsInterface,
            array![interface_id].span()
        )
            .unwrap_and_cast()
    }

    fn _call_on_erc721_received(
        from: ContractAddress, to: ContractAddress, token_id: u256, data: Span<felt252>
    ) -> felt252 {
        let mut args: Array<felt252> = array![];
        args.append_serde(get_caller_address());
        args.append_serde(from);
        args.append_serde(token_id);
        args.append_serde(data);

        call::try_selector_with_fallback(
            to, selectors::on_erc721_received, selectors::onERC721Received, args.span()
        )
            .unwrap_and_cast()
    }
}
