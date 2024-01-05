use core::traits::TryInto;
use debug::PrintTrait;
use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use openzeppelin::token::erc20::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
use snforge_std::{start_prank, stop_prank, CheatTarget};
use starknet::ContractAddress;
use unruggable::exchanges::SupportedExchanges;
use unruggable::exchanges::ekubo::launcher::{
    IEkuboLauncherDispatcher, IEkuboLauncherDispatcherTrait, EkuboLP
};
use unruggable::factory::interface::{IFactoryDispatcher, IFactoryDispatcherTrait};
use unruggable::locker::LockPosition;
use unruggable::locker::interface::{ILockManagerDispatcher, ILockManagerDispatcherTrait};
use unruggable::mocks::ekubo::swapper::{
    SwapParameters, ISimpleSwapperDispatcher, ISimpleSwapperDispatcherTrait
};
use unruggable::tests::addresses::{EKUBO_CORE};
use unruggable::tests::fork_tests::utils::{
    deploy_memecoin_through_factory_with_owner, sort_tokens, EKUBO_LAUNCHER_ADDRESS,
    EKUBO_SWAPPER_ADDRESS, deploy_ekubo_swapper, deploy_token0_with_owner, deploy_eth_with_owner
};
use unruggable::tests::unit_tests::utils::{
    OWNER, DEFAULT_MIN_LOCKTIME, pow_256, LOCK_MANAGER_ADDRESS, MEMEFACTORY_ADDRESS, RECIPIENT
};
use unruggable::tokens::interface::{
    IUnruggableMemecoinDispatcher, IUnruggableMemecoinDispatcherTrait
};
use unruggable::tokens::memecoin::LiquidityPosition;
use unruggable::utils::math::PercentageMath;

fn launch_memecoin_on_ekubo(
    counterparty_address: ContractAddress,
    fee: u128,
    tick_spacing: u128,
    starting_tick: i129,
    bound: u128
) -> (ContractAddress, u64, EkuboLP) {
    let owner = snforge_std::test_address();
    let (memecoin, memecoin_address) = deploy_memecoin_through_factory_with_owner(owner);
    let factory = IFactoryDispatcher { contract_address: MEMEFACTORY_ADDRESS() };
    let ekubo_launcher = IEkuboLauncherDispatcher { contract_address: EKUBO_LAUNCHER_ADDRESS() };
    let (id, position) = factory
        .launch_on_ekubo(
            memecoin_address, counterparty_address, fee, tick_spacing, starting_tick, bound
        );

    (memecoin_address, id, position)
}

fn swap_tokens_on_ekubo(
    token_in_address: ContractAddress,
    is_token1: bool,
    price_above_1: bool,
    token_out_address: ContractAddress,
    owner: ContractAddress,
    pool_key: PoolKey
) {
    let token_in = ERC20ABIDispatcher { contract_address: token_in_address };
    let token_out = ERC20ABIDispatcher { contract_address: token_out_address };

    let max_sqrt_ratio_limit = 6277100250585753475930931601400621808602321654880405518632;
    let min_sqrt_ratio_limit = 18446748437148339061;

    let (sqrt_limit_swap1, sqrt_limit_swap2) = if is_token1 {
        (max_sqrt_ratio_limit, min_sqrt_ratio_limit)
    } else {
        (min_sqrt_ratio_limit, max_sqrt_ratio_limit)
    };

    // First swap:
    // We swap counterparty (token1) for MEME (token0)
    // The initial price of the pool is 0.01counterparty/MEME = 100MEME/counterparty.
    // so the received amounts should be around 100x the amount of counterparty sent
    // with a 5% margin of error for the price impact.
    // since the pool price is expressend in counterparty/MEME, the price should move upwards (more counterparty for 1 meme)
    let swapper_address = deploy_ekubo_swapper();
    let ekubo_swapper = ISimpleSwapperDispatcher { contract_address: swapper_address };
    let first_amount_in = 2 * pow_256(10, 16); // The initial price was fixed
    let swap_params = SwapParameters {
        amount: i129 { mag: first_amount_in.low, sign: false // positive sign is exact input
         },
        is_token1,
        sqrt_ratio_limit: sqrt_limit_swap1, // higher than current
        skip_ahead: 0,
    };

    // We transfer tokens to the swapper contract, which performs the swap
    // This is required the way the swapper contract is coded.
    // It then sends back the funds to the caller
    start_prank(CheatTarget::One(token_in.contract_address), owner);
    token_in.transfer(swapper_address, first_amount_in);
    stop_prank(CheatTarget::One(token_in.contract_address));

    // If MEME/counterparty > 1 and we swap token1 for token0,
    // OR if MEME/counterparty < 1 and we swap token0 for token1,
    // we expect to receive 0.01x the amount of counterparty sent with a 5% margin of error
    let expected_output = if price_above_1 {
        PercentageMath::percent_mul(first_amount_in, 95)
    } else {
        PercentageMath::percent_mul(100 * first_amount_in, 9500)
    };
    ekubo_swapper
        .swap(
            pool_key: pool_key,
            swap_params: swap_params,
            recipient: owner,
            calculated_amount_threshold: expected_output
                .low, // threshold is min amount of received tokens
        );

    // Second swap:

    // We swap MEME (token0) for counterparty (token1)
    // the expected amount should be the initial amount,
    // minus the fees of the pool.
    let second_amount_in = token_out.balance_of(owner);
    let swap_params = SwapParameters {
        amount: i129 { mag: second_amount_in.low, sign: false // exact input
         },
        is_token1: !is_token1,
        sqrt_ratio_limit: sqrt_limit_swap2, // lower than current
        skip_ahead: 0,
    };
    let second_expected_output = PercentageMath::percent_mul(first_amount_in, 9940);
    let balance_token_in_before = token_in.balance_of(owner);

    start_prank(CheatTarget::One(token_out.contract_address), owner);
    token_out.transfer(swapper_address, second_amount_in);
    stop_prank(CheatTarget::One(token_out.contract_address));

    ekubo_swapper
        .swap(
            pool_key: pool_key,
            swap_params: swap_params,
            recipient: owner,
            calculated_amount_threshold: second_expected_output
                .low, // threshold is min amount of received tokens
        );

    let token_in_received = token_in.balance_of(owner) - balance_token_in_before;
    assert(token_in_received >= second_expected_output, 'swap output too low');
}

#[test]
#[fork("Mainnet")]
fn test_ekubo_launch_meme() {
    let owner = snforge_std::test_address();
    let (counterparty, counterparty_address) = deploy_eth_with_owner(owner);
    let starting_tick = i129 { sign: true, mag: 4600158 }; // 0.01ETH/MEME
    let (memecoin_address, id, position) = launch_memecoin_on_ekubo(
        counterparty_address, 0xc49ba5e353f7d00000000000000000, 5982, starting_tick, 88719042
    );
    let memecoin = IUnruggableMemecoinDispatcher { contract_address: memecoin_address };

    let (token0, token1) = sort_tokens(counterparty_address, memecoin_address);
    let pool_key = PoolKey {
        token0: position.pool_key.token0,
        token1: position.pool_key.token1,
        fee: position.pool_key.fee.try_into().unwrap(),
        tick_spacing: position.pool_key.tick_spacing.try_into().unwrap(),
        extension: position.pool_key.extension
    };

    let core = ICoreDispatcher { contract_address: EKUBO_CORE() };
    let liquidity = core.get_pool_liquidity(pool_key);
    let price = core.get_pool_price(pool_key);
    let reserve_memecoin = core.get_reserves(memecoin_address);
    let reserve_counterparty = core.get_reserves(counterparty_address);
    assert(reserve_counterparty == 0, 'reserve counterparty not 0');

    // Verify that the reserve of memecoin is within 0.5% of the (total supply minus the team allocation)
    let team_alloc = memecoin.get_team_allocation();
    let expected_reserve_lower_bound = PercentageMath::percent_mul(
        memecoin.totalSupply() - team_alloc, 9950,
    );
    assert(reserve_memecoin > expected_reserve_lower_bound, 'reserves holds too few token');
//TODO: check token info of minted LP
}


#[test]
#[fork("Mainnet")]
fn test_ekubo_swap_token0_price_below_1() {
    let owner = snforge_std::test_address();
    let (counterparty, counterparty_address) = deploy_eth_with_owner(owner);
    let starting_tick = i129 { sign: true, mag: 4600158 }; // 0.01ETH/MEME
    let (memecoin_address, id, position) = launch_memecoin_on_ekubo(
        counterparty_address, 0xc49ba5e353f7d00000000000000000, 5982, starting_tick, 88719042
    );
    let memecoin = IUnruggableMemecoinDispatcher { contract_address: memecoin_address };
    let counterparty = ERC20ABIDispatcher { contract_address: counterparty_address };
    let ekubo_launcher = IEkuboLauncherDispatcher { contract_address: EKUBO_LAUNCHER_ADDRESS() };
    // Test that swaps work correctly

    let (token0, token1) = sort_tokens(counterparty_address, memecoin_address);
    let pool_key = PoolKey {
        token0: position.pool_key.token0,
        token1: position.pool_key.token1,
        fee: position.pool_key.fee.try_into().unwrap(),
        tick_spacing: position.pool_key.tick_spacing.try_into().unwrap(),
        extension: position.pool_key.extension
    };
    // Check that swaps work correctly

    swap_tokens_on_ekubo(
        token_in_address: counterparty_address,
        is_token1: true,
        price_above_1: false,
        token_out_address: memecoin_address,
        owner: owner,
        pool_key: pool_key
    );

    // Test that the owner of the LP can withdraw fees from the launcher
    let recipient = RECIPIENT();
    ekubo_launcher.withdraw_fees(id, recipient);
    let balance_of_memecoin = memecoin.balance_of(recipient);
    let balance_of_counterparty = counterparty.balance_of(recipient);
    assert(balance_of_memecoin == 0, 'memecoin shouldnt collect fees');
    //TODO amount in dynamic
    assert(
        balance_of_counterparty == PercentageMath::percent_mul(2 * pow_256(10, 16), 0030),
        'should collect 0.3% of eth'
    );
}

#[test]
#[fork("Mainnet")]
fn test_ekubo_launch_meme_token1_price_below_1() {
    let owner = snforge_std::test_address();
    let (counterparty, counterparty_address) = deploy_token0_with_owner(owner);
    let starting_tick = i129 { sign: true, mag: 4600158 }; // 0.01ETH/MEME
    let (memecoin_address, id, position) = launch_memecoin_on_ekubo(
        counterparty_address, 0xc49ba5e353f7d00000000000000000, 5982, starting_tick, 88719042
    );
    let memecoin = IUnruggableMemecoinDispatcher { contract_address: memecoin_address };
    let counterparty = ERC20ABIDispatcher { contract_address: counterparty_address };
    let ekubo_launcher = IEkuboLauncherDispatcher { contract_address: EKUBO_LAUNCHER_ADDRESS() };

    // Test that swaps work correctly

    let (token0_address, token1_address) = sort_tokens(counterparty_address, memecoin_address);
    assert(token0_address == counterparty_address, 'token0 not counterparty');

    let pool_key = PoolKey {
        token0: position.pool_key.token0,
        token1: position.pool_key.token1,
        fee: position.pool_key.fee.try_into().unwrap(),
        tick_spacing: position.pool_key.tick_spacing.try_into().unwrap(),
        extension: position.pool_key.extension
    };

    let core = ICoreDispatcher { contract_address: EKUBO_CORE() };
    let liquidity = core.get_pool_liquidity(pool_key);
    let price = core.get_pool_price(pool_key);
    let reserve_memecoin = core.get_reserves(memecoin_address);
    let reserve_token0 = core.get_reserves(counterparty_address);
    assert(reserve_token0 == 0, 'reserve counterparty not 0');

    // Verify that the reserve of memecoin is within 0.5% of the (total supply minus the team allocation)
    let team_alloc = memecoin.get_team_allocation();
    let expected_reserve_lower_bound = PercentageMath::percent_mul(
        memecoin.totalSupply() - team_alloc, 9950,
    );
    assert(reserve_memecoin > expected_reserve_lower_bound, 'reserves holds too few token');

    swap_tokens_on_ekubo(
        token_in_address: counterparty_address,
        is_token1: false,
        price_above_1: false,
        token_out_address: memecoin_address,
        owner: owner,
        pool_key: pool_key
    );

    // Test that the owner of the LP can withdraw fees from the launcher
    let recipient = RECIPIENT();
    ekubo_launcher.withdraw_fees(id, recipient);
    let balance_of_memecoin = memecoin.balance_of(recipient);
    let balance_of_counterparty = counterparty.balance_of(recipient);
    assert(balance_of_memecoin == 0, 'memecoin shouldnt collect fees');
    //TODO amount in dynamic
    assert(
        balance_of_counterparty == PercentageMath::percent_mul(2 * pow_256(10, 16), 0030),
        'should collect 0.3% of eth'
    );
}


#[test]
#[fork("Mainnet")]
fn test_ekubo_launch_meme_token0_price_above_1() {
    let owner = snforge_std::test_address();
    let (counterparty, counterparty_address) = deploy_eth_with_owner(owner);
    let starting_tick = i129 { sign: false, mag: 4600158 }; // 100counterparty/MEME
    let (memecoin_address, id, position) = launch_memecoin_on_ekubo(
        counterparty_address, 0xc49ba5e353f7d00000000000000000, 5982, starting_tick, 88719042
    );
    let memecoin = IUnruggableMemecoinDispatcher { contract_address: memecoin_address };
    let counterparty = ERC20ABIDispatcher { contract_address: counterparty_address };
    let ekubo_launcher = IEkuboLauncherDispatcher { contract_address: EKUBO_LAUNCHER_ADDRESS() };

    // Test that swaps work correctly

    let (token0, token1) = sort_tokens(counterparty.contract_address, memecoin_address);
    // hardcoded

    let pool_key = PoolKey {
        token0: position.pool_key.token0,
        token1: position.pool_key.token1,
        fee: position.pool_key.fee.try_into().unwrap(),
        tick_spacing: position.pool_key.tick_spacing.try_into().unwrap(),
        extension: position.pool_key.extension
    };

    let core = ICoreDispatcher { contract_address: EKUBO_CORE() };
    let liquidity = core.get_pool_liquidity(pool_key);
    let price = core.get_pool_price(pool_key);
    let reserve_memecoin = core.get_reserves(memecoin_address);
    let reserve_fake_counterparty = core.get_reserves(counterparty_address);
    assert(reserve_fake_counterparty == 0, 'reserve counterparty not 0');

    // Verify that the reserve of memecoin is within 0.5% of the (total supply minus the team allocation)
    let team_alloc = memecoin.get_team_allocation();
    let expected_reserve_lower_bound = PercentageMath::percent_mul(
        memecoin.totalSupply() - team_alloc, 9950,
    );
    assert(reserve_memecoin > expected_reserve_lower_bound, 'reserves holds too few token');

    // // Check that swaps work correctly

    swap_tokens_on_ekubo(
        token_in_address: counterparty_address,
        is_token1: true,
        price_above_1: true,
        token_out_address: memecoin_address,
        owner: owner,
        pool_key: pool_key
    );

    // Test that the owner of the LP can withdraw fees from the launcher
    let recipient = RECIPIENT();
    ekubo_launcher.withdraw_fees(id, recipient);
    let balance_of_memecoin = memecoin.balance_of(recipient);
    let balance_of_counterparty = counterparty.balance_of(recipient);
    assert(balance_of_memecoin == 0, 'memecoin shouldnt collect fees');
    //TODO amount in dynamic
    assert(
        balance_of_counterparty == PercentageMath::percent_mul(2 * pow_256(10, 16), 0030),
        'should collect 0.3% of eth'
    );
}


#[test]
#[fork("Mainnet")]
fn test_ekubo_launch_meme_token1_price_above_1() {
    let owner = snforge_std::test_address();
    let (counterparty, counterparty_address) = deploy_token0_with_owner(owner);
    let starting_tick = i129 { sign: false, mag: 4600158 }; // 100counterparty/MEME
    let (memecoin_address, id, position) = launch_memecoin_on_ekubo(
        counterparty_address, 0xc49ba5e353f7d00000000000000000, 5982, starting_tick, 88719042
    );
    let memecoin = IUnruggableMemecoinDispatcher { contract_address: memecoin_address };
    let counterparty = ERC20ABIDispatcher { contract_address: counterparty_address };
    let ekubo_launcher = IEkuboLauncherDispatcher { contract_address: EKUBO_LAUNCHER_ADDRESS() };

    // Test that swaps work correctly

    let (token0_address, token1_address) = sort_tokens(
        counterparty.contract_address, memecoin_address
    );
    assert(token0_address == counterparty.contract_address, 'token0 not counterparty');

    let pool_key = PoolKey {
        token0: position.pool_key.token0,
        token1: position.pool_key.token1,
        fee: position.pool_key.fee.try_into().unwrap(),
        tick_spacing: position.pool_key.tick_spacing.try_into().unwrap(),
        extension: position.pool_key.extension
    };

    let core = ICoreDispatcher { contract_address: EKUBO_CORE() };
    let liquidity = core.get_pool_liquidity(pool_key);
    let price = core.get_pool_price(pool_key);
    let reserve_memecoin = core.get_reserves(memecoin_address);
    let reserve_token0 = core.get_reserves(counterparty_address);
    assert(reserve_token0 == 0, 'reserve counterparty not 0');

    // Verify that the reserve of memecoin is within 0.5% of the (total supply minus the team allocation)
    let team_alloc = memecoin.get_team_allocation();
    let expected_reserve_lower_bound = PercentageMath::percent_mul(
        memecoin.totalSupply() - team_alloc, 9950,
    );
    assert(reserve_memecoin > expected_reserve_lower_bound, 'reserves holds too few token');

    // Check that swaps work correctly

    swap_tokens_on_ekubo(
        token_in_address: counterparty_address,
        is_token1: false,
        price_above_1: true,
        token_out_address: memecoin_address,
        owner: owner,
        pool_key: pool_key
    );

    // Test that the owner of the LP can withdraw fees from the launcher
    let recipient = RECIPIENT();
    ekubo_launcher.withdraw_fees(id, recipient);
    let balance_of_memecoin = memecoin.balance_of(recipient);
    let balance_of_counterparty = counterparty.balance_of(recipient);
    assert(balance_of_memecoin == 0, 'memecoin shouldnt collect fees');
    //TODO amount in dynamic
    assert(
        balance_of_counterparty == PercentageMath::percent_mul(2 * pow_256(10, 16), 0030),
        'should collect 0.3% of eth'
    );
}

#[test]
#[fork("Mainnet")]
fn test_ekubo_launch_meme_with_pool_1percent() {
    let owner = snforge_std::test_address();
    let (counterparty, counterparty_address) = deploy_eth_with_owner(owner);
    let starting_tick = i129 { sign: true, mag: 4600158 }; // 0.01ETH/MEME
    let (memecoin_address, id, position) = launch_memecoin_on_ekubo(
        counterparty_address, 0x28f5c28f5c28f600000000000000000, 5982, starting_tick, 88719042
    );
    let memecoin = IUnruggableMemecoinDispatcher { contract_address: memecoin_address };

    let (token0, token1) = sort_tokens(counterparty_address, memecoin_address);
    let pool_key = PoolKey {
        token0: position.pool_key.token0,
        token1: position.pool_key.token1,
        fee: position.pool_key.fee.try_into().unwrap(),
        tick_spacing: position.pool_key.tick_spacing.try_into().unwrap(),
        extension: position.pool_key.extension
    };
    let core = ICoreDispatcher { contract_address: EKUBO_CORE() };
    let liquidity = core.get_pool_liquidity(pool_key);
    let price = core.get_pool_price(pool_key);
    let reserve_memecoin = core.get_reserves(memecoin_address);
    let reserve_fake_counterparty = core.get_reserves(counterparty_address);
    assert(reserve_fake_counterparty == 0, 'reserve counterparty not 0');

    // Verify that the reserve of memecoin is within 0.5% of the (total supply minus the team allocation)
    let team_alloc = memecoin.get_team_allocation();
    let expected_reserve_lower_bound = PercentageMath::percent_mul(
        memecoin.totalSupply() - team_alloc, 9950,
    );
    assert(reserve_memecoin > expected_reserve_lower_bound, 'reserves holds too few token');
}
//TODO! As there are no unit ekubo tests, we need to deeply test the whole flow of interaction with ekubo - including 
//TODO! launching with wrong parameters, as the frontend data cant be trusted


