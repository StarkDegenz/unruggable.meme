use openzeppelin::token::erc20::interface::{IERC20, ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
use starknet::ContractAddress;

#[starknet::contract]
mod Factory {
    use core::box::BoxTrait;
    use core::starknet::event::EventEmitter;
    use core::zeroable::Zeroable;
    use ekubo::types::i129::i129;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::access::ownable::ownable::OwnableComponent::InternalTrait;
    use openzeppelin::token::erc20::interface::{
        IERC20, ERC20ABIDispatcher, ERC20ABIDispatcherTrait
    };
    use poseidon::poseidon_hash_span;
    use starknet::SyscallResultTrait;
    use starknet::syscalls::deploy_syscall;
    use starknet::{
        ContractAddress, ClassHash, get_caller_address, get_contract_address, contract_address_const
    };
    use unruggable::errors;
    use unruggable::exchanges::{
        SupportedExchanges, ekubo_adapter, ekubo_adapter::EkuboPoolParameters, jediswap_adapter,
        jediswap_adapter::JediswapAdditionalParameters, ekubo::launcher::EkuboLP
    };
    use unruggable::factory::IFactory;
    use unruggable::tokens::UnruggableMemecoin::LiquidityType;
    use unruggable::tokens::interface::{
        IUnruggableMemecoinDispatcher, IUnruggableMemecoinDispatcherTrait
    };

    // Components.
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        MemecoinCreated: MemecoinCreated,
        MemecoinLaunched: MemecoinLaunched,
        #[flat]
        OwnableEvent: OwnableComponent::Event
    }

    #[derive(Drop, starknet::Event)]
    struct MemecoinCreated {
        owner: ContractAddress,
        name: felt252,
        symbol: felt252,
        initial_supply: u256,
        memecoin_address: ContractAddress
    }

    #[derive(Drop, starknet::Event)]
    struct MemecoinLaunched {
        memecoin_address: ContractAddress,
        quote_token: ContractAddress,
        exchange_name: felt252,
    }

    #[storage]
    struct Storage {
        memecoin_class_hash: ClassHash,
        amm_configs: LegacyMap<SupportedExchanges, ContractAddress>,
        //TODO: refactor to keep a list of deployed memecoins and expose it publicly
        deployed_memecoins: LegacyMap<ContractAddress, bool>,
        lock_manager_address: ContractAddress,
        // Components.
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        memecoin_class_hash: ClassHash,
        lock_manager_address: ContractAddress,
        mut amms: Span<(SupportedExchanges, ContractAddress)>
    ) {
        self.ownable.initializer(owner);
        self.memecoin_class_hash.write(memecoin_class_hash);
        self.lock_manager_address.write(lock_manager_address);

        // Add Exchanges configurations
        loop {
            match amms.pop_front() {
                Option::Some((amm, address)) => self.amm_configs.write(*amm, *address),
                Option::None => { break; }
            }
        };
    }

    #[abi(embed_v0)]
    impl FactoryImpl of IFactory<ContractState> {
        fn create_memecoin(
            ref self: ContractState,
            owner: ContractAddress,
            name: felt252,
            symbol: felt252,
            initial_supply: u256,
            initial_holders: Span<ContractAddress>,
            initial_holders_amounts: Span<u256>,
            transfer_limit_delay: u64,
            contract_address_salt: felt252,
        ) -> ContractAddress {
            let mut calldata = array![
                owner.into(), transfer_limit_delay.into(), name.into(), symbol.into()
            ];
            Serde::serialize(@initial_supply, ref calldata);
            Serde::serialize(@initial_holders.into(), ref calldata);
            Serde::serialize(@initial_holders_amounts.into(), ref calldata);

            let (memecoin_address, _) = deploy_syscall(
                self.memecoin_class_hash.read(), contract_address_salt, calldata.span(), false
            )
                .unwrap_syscall();

            // save memecoin address
            self.deployed_memecoins.write(memecoin_address, true);

            let caller = get_caller_address();

            self.emit(MemecoinCreated { owner, name, symbol, initial_supply, memecoin_address });

            memecoin_address
        }

        fn launch_on_jediswap(
            ref self: ContractState,
            memecoin_address: ContractAddress,
            quote_address: ContractAddress,
            quote_amount: u256,
            unlock_time: u64,
        ) -> ContractAddress {
            let memecoin = IUnruggableMemecoinDispatcher { contract_address: memecoin_address };
            assert(!memecoin.is_launched(), errors::ALREADY_LAUNCHED);
            assert(get_caller_address() == memecoin.owner(), errors::CALLER_NOT_OWNER);
            let quote_token = ERC20ABIDispatcher { contract_address: quote_address };
            let caller_address = get_caller_address();

            let router_address = self.exchange_address(SupportedExchanges::Jediswap);
            let mut pair_address = jediswap_adapter::JediswapAdapterImpl::create_and_add_liquidity(
                exchange_address: router_address,
                token_address: memecoin_address,
                quote_address: quote_address,
                additional_parameters: JediswapAdditionalParameters {
                    lock_manager_address: self.lock_manager_address(), unlock_time, quote_amount
                }
            );

            memecoin.set_launched(LiquidityType::ERC20(pair_address));
            self
                .emit(
                    MemecoinLaunched {
                        memecoin_address, quote_token: quote_address, exchange_name: 'Jediswap'
                    }
                );
            pair_address
        }

        fn launch_on_ekubo(
            ref self: ContractState,
            memecoin_address: ContractAddress,
            quote_address: ContractAddress,
            ekubo_parameters: EkuboPoolParameters,
        ) -> (u64, EkuboLP) {
            let memecoin = IUnruggableMemecoinDispatcher { contract_address: memecoin_address };
            let launchpad_address = self.exchange_address(SupportedExchanges::Ekubo);
            assert(get_caller_address() == memecoin.owner(), errors::CALLER_NOT_OWNER);
            assert(launchpad_address.is_non_zero(), errors::EXCHANGE_ADDRESS_ZERO);
            assert(!memecoin.is_launched(), errors::ALREADY_LAUNCHED); //TODO: error message
            assert(
                ekubo_parameters.starting_tick.mag.is_non_zero(), errors::PRICE_ZERO
            ); //TODO: test
            let quote_token = ERC20ABIDispatcher { contract_address: quote_address };
            let caller_address = get_caller_address();

            let (id, position) = ekubo_adapter::EkuboAdapterImpl::create_and_add_liquidity(
                exchange_address: launchpad_address,
                token_address: memecoin_address,
                quote_address: quote_address,
                additional_parameters: ekubo_parameters
            );

            memecoin.set_launched(LiquidityType::NFT(id));
            self
                .emit(
                    MemecoinLaunched {
                        memecoin_address, quote_token: quote_address, exchange_name: 'Ekubo'
                    }
                );
            (id, position)
        }

        fn lock_manager_address(self: @ContractState) -> ContractAddress {
            self.lock_manager_address.read()
        }

        fn exchange_address(self: @ContractState, amm: SupportedExchanges) -> ContractAddress {
            self.amm_configs.read(amm)
        }

        fn is_memecoin(self: @ContractState, address: ContractAddress) -> bool {
            self.deployed_memecoins.read(address)
        }
    }
}
