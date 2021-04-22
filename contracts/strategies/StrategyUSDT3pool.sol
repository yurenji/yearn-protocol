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
        if (_want > 0) { //如果tank=balance（tank大于0）则不需要再deposit资金了
            IERC20(want).safeApprove(_3pool, 0);
            IERC20(want).safeApprove(_3pool, _want);
            uint256 v = _want.mul(1e30).div(ICurveFi(_3pool).get_virtual_price());
            ICurveFi(_3pool).add_liquidity([0, 0, _want], v.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR)); // USDT存入3pool
        }
        uint256 _bal = IERC20(_3crv).balanceOf(address(this)); //上一步deposit产生的新3crv 可以存到yvault里面 
        if (_bal > 0) {
            IERC20(_3crv).safeApprove(y3crv, 0);
            IERC20(_3crv).safeApprove(y3crv, _bal); 
            yvERC20(y3crv).deposit(_bal); //// 3crv存入 yvault (获得 y3crv)
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
        if (_balance < _amount) { //本策略合约USDT余额小于要求的提款额
            _amount = _withdrawSome(_amount.sub(_balance)); //不够的部分从池子里面提取到本策略合约
            _amount = _amount.add(_balance);
            tank = 0; //策略余额部分全部提取完毕 
        } else { //策略合约余额足够
            if (tank >= _amount) tank = tank.sub(_amount); //从tank中提取 
            else tank = 0;
        }

        address _vault = IController(controller).vaults(address(want));
        require(_vault != address(0), "!vault"); // additional protection so we don't burn the funds
        uint256 _fee = _amount.mul(withdrawalFee).div(DENOMINATOR);
        //从策略合约转出给controller的 reward/fee vault 
        IERC20(want).safeTransfer(IController(controller).rewards(), _fee);
        IERC20(want).safeTransfer(_vault, _amount.sub(_fee));
    }

    //作用于y3CRV，提取到本策略合约
    function _withdrawSome(uint256 _amount) internal returns (uint256) {
        // 输入 _amount 是 USDT数量
        uint256 _amnt = _amount.mul(1e30).div(ICurveFi(_3pool).get_virtual_price()); // 3CRV数量
        uint256 _amt = _amnt.mul(1e18).div(yvERC20(y3crv).getPricePerFullShare()); // y3CRV数量
        uint256 _before = IERC20(_3crv).balanceOf(address(this));
        yvERC20(y3crv).withdraw(_amt); // 提取y3CRV 
        uint256 _after = IERC20(_3crv).balanceOf(address(this));
        return _withdrawOne(_after.sub(_before)); //从3pool 提取USDT 
    }

    // 作用于3pool，提取到本策略合约
    function _withdrawOne(uint256 _amnt) internal returns (uint256) {
        // 输入 _amnt 是3CRV数量 
        uint256 _before = IERC20(want).balanceOf(address(this));
        IERC20(_3crv).safeApprove(_3pool, 0);
        IERC20(_3crv).safeApprove(_3pool, _amnt);
        // 提取 3CRV， 获得USDT 
        ICurveFi(_3pool).remove_liquidity_one_coin(_amnt, 2, _amnt.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR).div(1e12));
        uint256 _after = IERC20(want).balanceOf(address(this));

        return _after.sub(_before); // USDT增加的数量
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
        require(msg.sender == governance, "!governance");
        require(IController(controller).approvedStrategies(want, _strategy), "!stategyAllowed");
        IERC20(y3crv).safeTransfer(_strategy, IERC20(y3crv).balanceOf(address(this)));
        IERC20(_3crv).safeTransfer(_strategy, IERC20(_3crv).balanceOf(address(this)));
        IERC20(want).safeTransfer(_strategy, IERC20(want).balanceOf(address(this)));
    }

    function forceD(uint256 _amount) external isAuthorized {
        //强制deposit， 输入_amount是USDT数量 
        IERC20(want).safeApprove(_3pool, 0);
        IERC20(want).safeApprove(_3pool, _amount);
        uint256 v = _amount.mul(1e30).div(ICurveFi(_3pool).get_virtual_price()); //3crv数量 
        ICurveFi(_3pool).add_liquidity([0, 0, _amount], v.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR)); //添加USDT到3pool 
        if (_amount < tank) tank = tank.sub(_amount); //更新tank
        else tank = 0;
        //添加 3crv 到 yvault 
        uint256 _bal = IERC20(_3crv).balanceOf(address(this)); 
        IERC20(_3crv).safeApprove(y3crv, 0);
        IERC20(_3crv).safeApprove(y3crv, _bal);
        yvERC20(y3crv).deposit(_bal);
    }

    function forceW(uint256 _amt) external isAuthorized {
        // 强制提取， 输入_amt是y3crv数量 
        uint256 _before = IERC20(_3crv).balanceOf(address(this));
        yvERC20(y3crv).withdraw(_amt);
        uint256 _after = IERC20(_3crv).balanceOf(address(this));
        _amt = _after.sub(_before); // y3crv被销毁，3crv被返还到策略合约（数量增加）

        IERC20(_3crv).safeApprove(_3pool, 0);
        IERC20(_3crv).safeApprove(_3pool, _amt); 
        _before = IERC20(want).balanceOf(address(this)); 
        // 从3pool 提取USDT，销毁3crv 
        ICurveFi(_3pool).remove_liquidity_one_coin(_amt, 2, _amt.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR).div(1e12));
        _after = IERC20(want).balanceOf(address(this)); //策略合约USDT增加
        tank = tank.add(_after.sub(_before)); //更新tank 
    }

    function drip() public isAuthorized {
         // 每次rebalance都先把 y3crv reward 分给 strategist 和 vault
        uint256 _p = yvERC20(y3crv).getPricePerFullShare();
        _p = _p.mul(ICurveFi(_3pool).get_virtual_price()).div(1e18);
        require(_p >= p, "backward"); // 保证净值是在增长的才有reward发出
        uint256 _r = (_p.sub(p)).mul(balanceOfy3CRV()).div(1e18);
        uint256 _s = _r.mul(strategistReward).div(DENOMINATOR);
        IERC20(y3crv).safeTransfer(strategist, _s.mul(1e18).div(_p));
        uint256 _t = _r.mul(treasuryFee).div(DENOMINATOR);
        IERC20(y3crv).safeTransfer(IController(controller).rewards(), _t.mul(1e18).div(_p));
        p = _p;
    }

    function tick() public view returns (uint256 _t, uint256 _c) {
        _t = ICurveFi(_3pool).balances(2).mul(threshold).div(DENOMINATOR);// 3pool中USDT数量的60%
        _c = balanceOfy3CRVinWant(); // 策略地址中剩余y3crv对应的USDT数量
    }

    function rebalance() public isAuthorized {
        drip();  
        (uint256 _t, uint256 _c) = tick();
        if (_c > _t) { //本策略已存入USDT（y3crv代表）大于3pool中USDT总量的60%
            _withdrawSome(_c.sub(_t));  //从3pool中提取出一些到本策略合约 （保证一个策略占总资金不超过60%）
            tank = IERC20(want).balanceOf(address(this)); //超过池子资金60%的部分放到tank
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
