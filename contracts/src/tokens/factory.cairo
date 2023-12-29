use openzeppelin::token::erc20::interface::{IERC20, ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
use starknet::ContractAddress;
use unruggable::amm::amm::AMM;


#[starknet::interface]
trait IUnruggableMemecoinFactory<TContractState> {
    /// Creates a new memecoin.
    ///
    /// This function deploys a new memecoin contract with the given parameters,
    /// transfers 1 ETH from the caller to the new memecoin, and emits a `MemeCoinCreated` event.
    ///
    /// * `owner` - The address of the Memecoin contract owner.
    /// * `locker_address` - The address of the locker contract associated with the Memecoin.
    /// * `name` - The name of the Memecoin.
    /// * `symbol` - The symbol of the Memecoin.
    /// * `initial_supply` - The initial supply of the Memecoin.
    /// * `initial_holders` - An array containing the initial holders' addresses.
    /// * `initial_holders_amounts` - An array containing the initial amounts held by each corresponding initial holder.
    /// * `contract_address_salt` - A unique salt value for contract deployment
    ///
    /// # Returns
    ///
    /// The address of the newly created Memecoin smart contract.
    fn create_memecoin(
        ref self: TContractState,
        owner: ContractAddress,
        locker_address: ContractAddress,
        name: felt252,
        symbol: felt252,
        initial_supply: u256,
        initial_holders: Span<ContractAddress>,
        initial_holders_amounts: Span<u256>,
        eth_contract: ERC20ABIDispatcher,
        contract_address_salt: felt252
    ) -> ContractAddress;

    /// Returns the router address for a given AMM, provided that this AMM
    /// was registered in the factory upon initialization.
    ///
    /// # Arguments
    ///
    /// * `amm_name` - The name of the AMM for which to retrieve the contract address.
    ///
    /// # Returns
    ///
    /// * `ContractAddress` - The contract address associated with the given AMM name.
    fn amm_router_address(self: @TContractState, amm_name: felt252) -> ContractAddress;

    /// Checks if a given address is a memecoin.
    ///
    /// This function will only return true if the memecoin was created by this factory.
    ///
    /// # Arguments
    ///
    /// * `address` - The address to check.
    ///
    /// # Returns
    ///
    /// * `bool` - Returns true if the address is a memecoin, false otherwise.
    fn is_memecoin(self: @TContractState, address: ContractAddress) -> bool;
}

#[starknet::contract]
mod UnruggableMemecoinFactory {
    use core::box::BoxTrait;
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
    use super::IUnruggableMemecoinFactory;
    use unruggable::amm::amm::AMM;

    // Components.
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        MemeCoinCreated: MemeCoinCreated,
        #[flat]
        OwnableEvent: OwnableComponent::Event
    }

    #[derive(Drop, starknet::Event)]
    struct MemeCoinCreated {
        owner: ContractAddress,
        name: felt252,
        symbol: felt252,
        initial_supply: u256,
        memecoin_address: ContractAddress
    }

    const ETH_UNIT_DECIMALS: u256 = 1000000000000000000;

    #[storage]
    struct Storage {
        memecoin_class_hash: ClassHash,
        amm_configs: LegacyMap<felt252, ContractAddress>,
        deployed_memecoins: LegacyMap<ContractAddress, bool>,
        // Components.
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        memecoin_class_hash: ClassHash,
        mut amms: Span<AMM>
    ) {
        // Initialize the owner.
        self.ownable.initializer(owner);
        self.memecoin_class_hash.write(memecoin_class_hash);

        // Add AMMs configurations
        loop {
            match amms.pop_front() {
                Option::Some(amm) => self.amm_configs.write(*amm.name, *amm.router_address),
                Option::None => { break; }
            }
        };
    }

    #[abi(embed_v0)]
    impl UnruggableMemeCoinFactoryImpl of IUnruggableMemecoinFactory<ContractState> {
        fn create_memecoin(
            ref self: ContractState,
            owner: ContractAddress,
            locker_address: ContractAddress,
            name: felt252,
            symbol: felt252,
            initial_supply: u256,
            initial_holders: Span<ContractAddress>,
            initial_holders_amounts: Span<u256>,
            eth_contract: ERC20ABIDispatcher,
            contract_address_salt: felt252
        ) -> ContractAddress {
            // General calldata
            let mut calldata = serialize_calldata(
                owner, locker_address, name, symbol, initial_supply
            );
            Serde::serialize(@initial_holders.into(), ref calldata);
            Serde::serialize(@initial_holders_amounts.into(), ref calldata);

            let (memecoin_address, _) = deploy_syscall(
                self.memecoin_class_hash.read(), contract_address_salt, calldata.span(), false
            )
                .unwrap_syscall();

            // save memecoin address
            self.deployed_memecoins.write(memecoin_address, true);

            let caller = get_caller_address();
            //TODO(make the initial liquidity a parameter)
            let eth_amount: u256 = 1 * ETH_UNIT_DECIMALS;
            assert(
                eth_contract.allowance(caller, get_contract_address()) == eth_amount,
                'ETH allowance not enough'
            );
            eth_contract
                .transferFrom(sender: caller, recipient: memecoin_address, amount: eth_amount);

            //TODO(audit): why does it matter if the coin has _more_ than 1 ETH?
            assert(
                eth_contract.balanceOf(memecoin_address) == eth_amount, 'memecoin should have 1ETH'
            );

            self.emit(MemeCoinCreated { owner, name, symbol, initial_supply, memecoin_address });

            memecoin_address
        }

        fn amm_router_address(self: @ContractState, amm_name: felt252) -> ContractAddress {
            self.amm_configs.read(amm_name)
        }

        fn is_memecoin(self: @ContractState, address: ContractAddress) -> bool {
            self.deployed_memecoins.read(address)
        }
    }

    /// Serializes input parameters into calldata.
    ///
    /// # Arguments
    ///
    /// * `owner` - The address of the contract owner.
    /// * `locker_address` - The address of the locker contract associated with the contract.
    /// * `name` - The name of the contract.
    /// * `symbol` - The symbol of the contract.
    /// * `initial_supply` - The initial supply of the contract.
    ///
    /// # Returns
    ///
    /// An array containing the serialized calldata.
    fn serialize_calldata(
        owner: ContractAddress,
        locker_address: ContractAddress,
        name: felt252,
        symbol: felt252,
        initial_supply: u256
    ) -> Array<felt252> {
        //TODO(fix): serialize_calldata shouldn't have a hardcoded value here. - or at least, it should be named.
        let mut calldata = array![
            owner.into(), locker_address.into(), 1000.into(), name.into(), symbol.into()
        ]; // Third param should be lock delay.
        Serde::serialize(@initial_supply, ref calldata);
        calldata
    }
}
