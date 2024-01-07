use ekubo::types::i129::i129;
use openzeppelin::token::erc20::ERC20ABIDispatcher;
use starknet::ContractAddress;
use unruggable::exchanges::SupportedExchanges;
use unruggable::exchanges::ekubo::launcher::EkuboLP;
use unruggable::exchanges::ekubo_adapter::EkuboPoolParameters;

#[starknet::interface]
trait IFactory<TContractState> {
    /// Deploys a new memecoin, using the class hash that was registered in the factory upon initialization.
    ///
    /// This function deploys a new memecoin contract with the given parameters,
    /// and emits a `MemecoinCreated` event.
    ///
    /// * `owner` - The address of the Memecoin contract owner.
    /// * `name` - The name of the Memecoin.
    /// * `symbol` - The symbol of the Memecoin.
    /// * `initial_supply` - The initial supply of the Memecoin.
    /// * `initial_holders` - An array containing the initial holders' addresses.
    /// * `initial_holders_amounts` - An array containing the initial amounts held by each corresponding initial holder.
    /// * `transfer_limit_delay` - The delay in seconds during which transfers will be limited to a % of max supply after launch.
    /// * `quote_token` - The address of the quote token
    /// * `contract_address_salt` - A unique salt value for contract deployment
    ///
    /// # Returns
    ///
    /// The address of the newly created Memecoin smart contract.
    fn create_memecoin(
        ref self: TContractState,
        owner: ContractAddress,
        name: felt252,
        symbol: felt252,
        initial_supply: u256,
        initial_holders: Span<ContractAddress>,
        initial_holders_amounts: Span<u256>,
        transfer_limit_delay: u64,
        contract_address_salt: felt252
    ) -> ContractAddress;

    /// Launches the memecoin on Jediswap by creating a liquidity pair and adding liquidity to it.
    ///
    /// This function can only be called by the owner of the memecoin and only if the memecoin has not been launched yet.
    /// Launching on jediswap requires `quote_amount` quote tokens to be approved for transfer to the factory.
    /// It creates a liquidity pair for the memecoin and the quote token on Jediswap, adds liquidity to it, and sets the memecoin as launched.
    ///
    /// # Arguments
    ///
    /// * `memecoin_address` - The address of the memecoin contract.
    /// * `quote_address` - The address of the quote token contract.
    /// * `quote_amount` - The amount of quote tokens to add as liquidity.
    /// * `unlock_time` - The timestamp when the liquidity can be unlocked.
    ///
    /// # Returns
    ///
    /// * `ContractAddress` - The address of the created liquidity pair.
    ///
    /// # Panics
    ///
    /// This function will panic if:
    ///
    /// * The caller's address is not the same as the `owner` of the memecoin (error code: `errors::CALLER_NOT_OWNER`).
    /// * The memecoin has already been launched (error code: `errors::ALREADY_LAUNCHED`).
    ///
    fn launch_on_jediswap(
        ref self: TContractState,
        memecoin_address: ContractAddress,
        quote_address: ContractAddress,
        quote_amount: u256,
        unlock_time: u64,
    ) -> ContractAddress;

    /// Launches the memecoin on Ekubo by creating a pool with a set price and adding the memetoken to it.
    ///
    /// This function can only be called by the owner of the memecoin and only if the memecoin has not been launched yet.
    /// It creates a liquidity pair for the memecoin and a quote token on Ekubo, adds liquidity to it, and sets the memecoin as launched.
    ///
    /// # Arguments
    ///
    /// * `memecoin_address` - The address of the memecoin contract.
    /// * `quote_address` - The address of the quote token contract.
    /// * `ekubo_parameters` - The parameters for the ekubo liquidity pool, including:
    ///     - `fee` - The fee for the liquidity pair.
    ///     - `tick_spacing` - The spacing between ticks for the liquidity pool.
    ///     - `starting_tick` - The starting tick for the liquidity pool.
    ///     - `bound` - The bound for the liquidity pool - should be set to the max tick for this pool (the sign is determined in the contract).
    ///
    /// # Returns
    ///
    /// * `u64` - The ID of the created liquidity pool.
    ///
    /// # Panics
    ///
    /// This function will panic if:
    ///
    /// * The caller's address is not the same as the `owner` of the memecoin (error code: `errors::CALLER_NOT_OWNER`).
    /// * The memecoin has already been launched (error message: 'memecoin already launched').
    ///
    fn launch_on_ekubo(
        ref self: TContractState,
        memecoin_address: ContractAddress,
        quote_address: ContractAddress,
        ekubo_parameters: EkuboPoolParameters,
    ) -> (u64, EkuboLP);

    /// Returns the router address for a given Exchange, provided that this Exchange
    /// was registered in the factory upon initialization.
    ///
    /// # Arguments
    ///
    /// * `amm_name` - The name of the Exchange for which to retrieve the contract address.
    ///
    /// # Returns
    ///
    /// * `ContractAddress` - The contract address associated with the given Exchange name.
    fn exchange_address(self: @TContractState, amm: SupportedExchanges) -> ContractAddress;


    /// Returns the locker address for the memecoins of this factory.
    ///
    /// # Returns
    ///
    /// * `ContractAddress` - The contract address associated with the given Exchange name.
    fn lock_manager_address(self: @TContractState) -> ContractAddress;

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
