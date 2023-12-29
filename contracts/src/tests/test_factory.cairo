use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
use snforge_std::{declare, ContractClassTrait, start_prank, stop_prank, CheatTarget};
use starknet::{ContractAddress, contract_address_const};
use unruggable::amm::amm::{AMM, AMMV2, AMMTrait};

use unruggable::tests::utils::{
    deploy_amm_factory_and_router, deploy_meme_factory, deploy_locker, deploy_eth, OWNER, NAME,
    SYMBOL, ETH_INITIAL_SUPPLY, INITIAL_HOLDERS, INITIAL_HOLDERS_AMOUNTS, SALT
};
use unruggable::tokens::erc20::{ERC20Token};
use unruggable::tokens::factory::{
    IUnruggableMemecoinFactory, IUnruggableMemecoinFactoryDispatcher,
    IUnruggableMemecoinFactoryDispatcherTrait
};
use unruggable::tokens::interface::{
    IUnruggableMemecoin, IUnruggableMemecoinDispatcher, IUnruggableMemecoinDispatcherTrait
};

const ETH_UNIT_DECIMALS: u256 = 1000000000000000000;

fn instantiate_params() -> (
    ContractAddress,
    felt252,
    felt252,
    u256,
    ContractAddress,
    ContractAddress,
    Span<ContractAddress>,
    Span<u256>,
    ERC20ABIDispatcher,
    felt252
) {
    let owner = contract_address_const::<42>();
    let name = 'UnruggableMemecoin';
    let symbol = 'UM';
    let initial_supply = 1000;
    let initial_holder_1 = contract_address_const::<44>();
    let initial_holder_2 = contract_address_const::<45>();
    let initial_holders = array![initial_holder_1, initial_holder_2].span();
    let initial_holders_amounts = array![50, 50].span();
    let erc20_token = declare('ERC20Token');
    let eth_amount: u256 = 2 * ETH_UNIT_DECIMALS;
    let erc20_calldata: Array<felt252> = array![
        eth_amount.low.into(), eth_amount.high.into(), owner.into()
    ];
    let eth = erc20_token.deploy(@erc20_calldata).unwrap();
    let contract_address_salt = 'salty';
    (
        owner,
        name,
        symbol,
        initial_supply,
        initial_holder_1,
        initial_holder_2,
        initial_holders,
        initial_holders_amounts,
        ERC20ABIDispatcher { contract_address: eth },
        contract_address_salt
    )
}

#[test]
fn test_amm_router_address() {
    let (_, router_address) = deploy_amm_factory_and_router();
    let memecoin_factory_address = deploy_meme_factory(router_address);
    let memecoin_factory = IUnruggableMemecoinFactoryDispatcher {
        contract_address: memecoin_factory_address
    };

    let amm_router_address = memecoin_factory
        .amm_router_address(amm_name: AMMV2::JediSwap.to_string());
    assert(amm_router_address == router_address, 'wrong amm router_address');
}

#[test]
fn test_is_memecoin() {
    // Required contracts
    let (_, router_address) = deploy_amm_factory_and_router();
    let memecoin_factory_address = deploy_meme_factory(router_address);
    let memecoin_factory = IUnruggableMemecoinFactoryDispatcher {
        contract_address: memecoin_factory_address
    };
    let locker_address = deploy_locker();
    let (eth, eth_address) = deploy_eth();

    let eth_amount: u256 = eth.total_supply() / 2; // 50% of supply

    start_prank(CheatTarget::One(eth.contract_address), OWNER());
    eth.approve(memecoin_factory_address, eth_amount);
    stop_prank(CheatTarget::One(eth.contract_address));

    start_prank(CheatTarget::One(memecoin_factory.contract_address), OWNER());
    let memecoin_address = memecoin_factory
        .create_memecoin(
            owner: OWNER(),
            :locker_address,
            name: NAME(),
            symbol: SYMBOL(),
            initial_supply: ETH_INITIAL_SUPPLY(),
            initial_holders: INITIAL_HOLDERS(),
            initial_holders_amounts: INITIAL_HOLDERS_AMOUNTS(),
            eth_contract: eth,
            contract_address_salt: SALT(),
        );
    stop_prank(CheatTarget::One(memecoin_factory.contract_address));

    assert(memecoin_factory.is_memecoin(address: memecoin_address), 'should be memecoin');
    assert(
        !memecoin_factory.is_memecoin(address: 'random address'.try_into().unwrap()),
        'should not be memecoin'
    );
}


#[test]
fn test_create_memecoin() {
    // Required contracts
    let (_, router_address) = deploy_amm_factory_and_router();
    let memecoin_factory_address = deploy_meme_factory(router_address);
    let memecoin_factory = IUnruggableMemecoinFactoryDispatcher {
        contract_address: memecoin_factory_address
    };
    let locker_address = deploy_locker();
    let (eth, eth_address) = deploy_eth();

    let eth_amount: u256 = eth.total_supply() / 2; // 50% of supply

    start_prank(CheatTarget::One(eth.contract_address), OWNER());
    eth.approve(memecoin_factory_address, eth_amount);
    stop_prank(CheatTarget::One(eth.contract_address));

    start_prank(CheatTarget::One(memecoin_factory.contract_address), OWNER());
    let memecoin_address = memecoin_factory
        .create_memecoin(
            owner: OWNER(),
            :locker_address,
            name: NAME(),
            symbol: SYMBOL(),
            initial_supply: ETH_INITIAL_SUPPLY(),
            initial_holders: INITIAL_HOLDERS(),
            initial_holders_amounts: INITIAL_HOLDERS_AMOUNTS(),
            eth_contract: eth,
            contract_address_salt: SALT(),
        );
    stop_prank(CheatTarget::One(memecoin_factory.contract_address));

    let memecoin = IUnruggableMemecoinDispatcher { contract_address: memecoin_address };

    assert(memecoin.name() == NAME(), 'wrong memecoin name');
    assert(memecoin.symbol() == SYMBOL(), 'wrong memecoin symbol');
    // initial supply - initial holder balance
    assert(
        memecoin.balanceOf(memecoin_address) == ETH_INITIAL_SUPPLY() - 100, 'wrong initial supply'
    );
    assert(memecoin.balanceOf(*INITIAL_HOLDERS()[0]) == 50, 'wrong initial_holder_1 balance');
    assert(memecoin.balanceOf(*INITIAL_HOLDERS()[1]) == 50, 'wrong initial_holder_2 balance');
}

