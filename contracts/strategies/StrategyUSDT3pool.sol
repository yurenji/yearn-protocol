pragma solidity ^0.5.17;

import "@openzeppelinV2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelinV2/contracts/math/SafeMath.sol";
import "@openzeppelinV2/contracts/utils/Address.sol";
import "@openzeppelinV2/contracts/token/ERC20/SafeERC20.sol";

import "../../interfaces/yearn/IController.sol";
import "../../interfaces/curve/Curve.sol";

interface yvERC20 {
    function deposit(uint256) external;

    function withdraw(uint256) external;

    function earn() external;

    // https://docs.yearn.finance/developers/yvaults-documentation/vault-interfaces#function-getpriceperfullshare
    // LP token price in native token 
    function getPricePerFullShare() external view returns (uint256);
}

/*

 A strategy must implement the following calls;
 
 - deposit()
 - withdraw(address) must exclude any tokens used in the yield - Controller role - withdraw should return to Controller
 - withdraw(uint) - Controller | Vault role - withdraw should always return to vault
 - withdrawAll() - Controller | Vault role - withdraw should always return to vault
 - balanceOf()
 
 Where possible, strategies must remain as immutable as possible, instead of updating variables, we update the contract by linking it in the controller
 
*/

contract StrategyUSDT3pool {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public constant want = address(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    address public constant _3pool = address(0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7);
    address public constant _3crv = address(0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490);
    address public constant y3crv = address(0x9cA85572E6A3EbF24dEDd195623F188735A5179f);

    address public governance;
    address public controller;
    address public strategist;

    uint256 public constant DENOMINATOR = 10000;
    uint256 public treasuryFee = 500;
    uint256 public withdrawalFee = 0;
    uint256 public strategistReward = 50;
    uint256 public threshold = 6000;
    uint256 public slip = 100;
    uint256 public tank = 0;
    uint256 public p = 0;

    event Threshold(address indexed strategy);

    modifier isAuthorized() {
        require(msg.sender == governance || msg.sender == strategist || msg.sender == controller || msg.sender == address(this), "!authorized");
        _;
    }

    constructor(address _controller) public {
        governance = msg.sender;
        strategist = msg.sender;
        controller = _controller;
    }

    function getName() external pure returns (string memory) {
        return "StrategyUSDT3pool";
    }

    function deposit() public isAuthorized {
        rebalance();
        uint256 _want = (IERC20(want).balanceOf(address(this))).sub(tank);
        if (_want > 0) { //if tank=balance（tank>0）no need to deposit more money
            IERC20(want).safeApprove(_3pool, 0);
            IERC20(want).safeApprove(_3pool, _want);
            uint256 v = _want.mul(1e30).div(ICurveFi(_3pool).get_virtual_price());
            ICurveFi(_3pool).add_liquidity([0, 0, _want], v.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR)); // USDT存入3pool
        }
        uint256 _bal = IERC20(_3crv).balanceOf(address(this)); //previous deposit creates 3crv, which can be deposited in yvault
        if (_bal > 0) {
            IERC20(_3crv).safeApprove(y3crv, 0);
            IERC20(_3crv).safeApprove(y3crv, _bal); 
            yvERC20(y3crv).deposit(_bal); //// 3crv deposit in yvault (get y3crv)
        }
    }

    // Controller only function for creating additional rewards from dust
    function withdraw(IERC20 _asset) external returns (uint256 balance) {
        require(msg.sender == controller, "!controller");
        require(want != address(_asset), "want");
        require(_3crv != address(_asset), "3crv");
        require(y3crv != address(_asset), "y3crv");
        balance = _asset.balanceOf(address(this));
        _asset.safeTransfer(controller, balance);
    }

    // Withdraw partial funds, normally used with a vault withdrawal
    function withdraw(uint256 _amount) external {
        require(msg.sender == controller, "!controller");

        rebalance();
        uint256 _balance = IERC20(want).balanceOf(address(this));
        if (_balance < _amount) { //strategy contract'USDT balance < required withdraw amount 
            _amount = _withdrawSome(_amount.sub(_balance)); //withdraw some from pool to strategy 
            _amount = _amount.add(_balance);
            tank = 0; //strategy balance is empty after withdraw
        } else { //strategy balance is enough 
            if (tank >= _amount) tank = tank.sub(_amount); //widthdraw from tank 
            else tank = 0;
        }

        address _vault = IController(controller).vaults(address(want));
        require(_vault != address(0), "!vault"); // additional protection so we don't burn the funds
        uint256 _fee = _amount.mul(withdrawalFee).div(DENOMINATOR);
        //from strategy to controller's reward/fee vault 
        IERC20(want).safeTransfer(IController(controller).rewards(), _fee);
        IERC20(want).safeTransfer(_vault, _amount.sub(_fee));
    }

    //apply to y3CRV，withdraw to strategy 
    function _withdrawSome(uint256 _amount) internal returns (uint256) {
        // input _amount is USDT amount
        uint256 _amnt = _amount.mul(1e30).div(ICurveFi(_3pool).get_virtual_price()); // 3CRV amount 
        uint256 _amt = _amnt.mul(1e18).div(yvERC20(y3crv).getPricePerFullShare()); // y3CRV amount
        uint256 _before = IERC20(_3crv).balanceOf(address(this));
        yvERC20(y3crv).withdraw(_amt); // withdraw y3CRV 
        uint256 _after = IERC20(_3crv).balanceOf(address(this));
        return _withdrawOne(_after.sub(_before)); //withdraw USDT from 3Pool
    }

    // apply to 3pool，withdraw to strategy 
    function _withdrawOne(uint256 _amnt) internal returns (uint256) {
        // input _amnt is 3CRV amount
        uint256 _before = IERC20(want).balanceOf(address(this));
        IERC20(_3crv).safeApprove(_3pool, 0);
        IERC20(_3crv).safeApprove(_3pool, _amnt);
        // withdraw 3CRV， get USDT 
        ICurveFi(_3pool).remove_liquidity_one_coin(_amnt, 2, _amnt.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR).div(1e12));
        uint256 _after = IERC20(want).balanceOf(address(this));

        return _after.sub(_before); // USDT increased amount 
    }

    // Withdraw all funds, normally used when migrating strategies
    function withdrawAll() external returns (uint256 balance) {
        require(msg.sender == controller, "!controller");
        _withdrawAll();

        balance = IERC20(want).balanceOf(address(this));

        address _vault = IController(controller).vaults(address(want));
        require(_vault != address(0), "!vault"); // additional protection so we don't burn the funds
        IERC20(want).safeTransfer(_vault, balance);
    }

    function _withdrawAll() internal {
        uint256 _y3crv = IERC20(y3crv).balanceOf(address(this));
        if (_y3crv > 0) {
            yvERC20(y3crv).withdraw(_y3crv);
            _withdrawOne(IERC20(_3crv).balanceOf(address(this)));
        }
    }

    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    function balanceOf3CRV() public view returns (uint256) {
        return IERC20(_3crv).balanceOf(address(this));
    }

    function balanceOf3CRVinWant() public view returns (uint256) {
        return balanceOf3CRV().mul(ICurveFi(_3pool).get_virtual_price()).div(1e30);
    }

    function balanceOfy3CRV() public view returns (uint256) {
        return IERC20(y3crv).balanceOf(address(this));
    }

    function balanceOfy3CRVin3CRV() public view returns (uint256) {
        return balanceOfy3CRV().mul(yvERC20(y3crv).getPricePerFullShare()).div(1e18);
    }

    function balanceOfy3CRVinWant() public view returns (uint256) {
        return balanceOfy3CRVin3CRV().mul(ICurveFi(_3pool).get_virtual_price()).div(1e30);
    }

    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfy3CRVinWant());
    }

    function migrate(address _strategy) external {
        // only governance can call this
        require(msg.sender == governance, "!governance");
        // new strategy must be approved
        require(IController(controller).approvedStrategies(want, _strategy), "!stategyAllowed");
        // transfer all assets(USDT,3crv, y3crv) to new strategy
        IERC20(y3crv).safeTransfer(_strategy, IERC20(y3crv).balanceOf(address(this)));
        IERC20(_3crv).safeTransfer(_strategy, IERC20(_3crv).balanceOf(address(this)));
        IERC20(want).safeTransfer(_strategy, IERC20(want).balanceOf(address(this)));
    }

    function forceD(uint256 _amount) external isAuthorized {
        //force deposit， input _amount is USDT amount
        IERC20(want).safeApprove(_3pool, 0);
        IERC20(want).safeApprove(_3pool, _amount);
        uint256 v = _amount.mul(1e30).div(ICurveFi(_3pool).get_virtual_price()); //3crv amount
        ICurveFi(_3pool).add_liquidity([0, 0, _amount], v.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR)); //add USDT to 3pool 
        if (_amount < tank) tank = tank.sub(_amount); //update tank
        else tank = 0;
        //add 3crv to yvault 
        uint256 _bal = IERC20(_3crv).balanceOf(address(this)); 
        IERC20(_3crv).safeApprove(y3crv, 0);
        IERC20(_3crv).safeApprove(y3crv, _bal);
        yvERC20(y3crv).deposit(_bal);
    }

    function forceW(uint256 _amt) external isAuthorized {
        // force withdraw, input _amt is y3crv amount
        uint256 _before = IERC20(_3crv).balanceOf(address(this));
        yvERC20(y3crv).withdraw(_amt);
        uint256 _after = IERC20(_3crv).balanceOf(address(this));
        _amt = _after.sub(_before); // y3crv decrease，3crv returned to strategy（amount increase）

        IERC20(_3crv).safeApprove(_3pool, 0);
        IERC20(_3crv).safeApprove(_3pool, _amt); 
        _before = IERC20(want).balanceOf(address(this)); 
        // from 3pool withdraw USDT，decrease 3crv 
        ICurveFi(_3pool).remove_liquidity_one_coin(_amt, 2, _amt.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR).div(1e12));
        _after = IERC20(want).balanceOf(address(this)); //strategy USDT increase 
        tank = tank.add(_after.sub(_before)); //update tank 
    }

    function drip() public isAuthorized {
         // every rebalance will distribute y3crv reward to strategist/vault
        uint256 _p = yvERC20(y3crv).getPricePerFullShare();
        _p = _p.mul(ICurveFi(_3pool).get_virtual_price()).div(1e18);
        require(_p >= p, "backward"); // make sure LP value increased before reward send out 
        uint256 _r = (_p.sub(p)).mul(balanceOfy3CRV()).div(1e18);
        uint256 _s = _r.mul(strategistReward).div(DENOMINATOR);
        IERC20(y3crv).safeTransfer(strategist, _s.mul(1e18).div(_p));
        uint256 _t = _r.mul(treasuryFee).div(DENOMINATOR);
        IERC20(y3crv).safeTransfer(IController(controller).rewards(), _t.mul(1e18).div(_p));
        p = _p;
    }

    function tick() public view returns (uint256 _t, uint256 _c) {
        _t = ICurveFi(_3pool).balances(2).mul(threshold).div(DENOMINATOR);// 60% of USDT in 3Pool
        _c = balanceOfy3CRVinWant(); // strategy's y3crv value in USDT
    }

    function rebalance() public isAuthorized {
        drip();  
        (uint256 _t, uint256 _c) = tick();
        if (_c > _t) { //strategy'deposited USDT（y3crv represented）> 60% of USDT in 3Pool
            _withdrawSome(_c.sub(_t));  //withdraw some USDT from 3Pool to strategy
            tank = IERC20(want).balanceOf(address(this)); //the >60% part is moved to tank
            emit Threshold(address(this));
        }
    }

    function setGovernance(address _governance) external {
        require(msg.sender == governance, "!governance");
        governance = _governance;
    }

    function setIController(address _controller) external {
        require(msg.sender == governance, "!governance");
        controller = _controller;
    }

    function setStrategist(address _strategist) external {
        require(msg.sender == governance || msg.sender == strategist, "!gs");
        strategist = _strategist;
    }

    function setWithdrawalFee(uint256 _withdrawalFee) external {
        require(msg.sender == governance, "!governance");
        withdrawalFee = _withdrawalFee;
    }

    function setTreasuryFee(uint256 _treasuryFee) external {
        require(msg.sender == governance, "!governance");
        treasuryFee = _treasuryFee;
    }

    function setStrategistReward(uint256 _strategistReward) external {
        require(msg.sender == governance, "!governance");
        strategistReward = _strategistReward;
    }

    function setThreshold(uint256 _threshold) external {
        require(msg.sender == strategist || msg.sender == governance, "!sg");
        threshold = _threshold;
    }

    function setSlip(uint256 _slip) external {
        require(msg.sender == strategist || msg.sender == governance, "!sg");
        slip = _slip;
    }
}
