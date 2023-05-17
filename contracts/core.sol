// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "./lib/utils/Address.sol";
import "./lib/utils/math/SafeMath.sol";

import "./lib/token/ERC20/IERC20.sol";
import "./lib/token/ERC20/extensions/IERC20Metadata.sol";
import "./lib/token/ERC20/utils/SafeERC20.sol";
import "./lib/security/ReentrancyGuard.sol";

/**
 * @title IFlashLoanReceiver interface
 * @notice Interface for the Unilend fee IFlashLoanReceiver.
 * @dev implement this interface to develop a flashloan-compatible flashLoanReceiver contract
 **/
interface IFlashLoanReceiver {
    function executeOperation(
        address _reserve,
        uint256 _amount,
        uint256 _fee,
        bytes calldata _params
    ) external;
}

interface IUnilendV2Oracle {
    function getAssetPrice(
        address token0,
        address token1,
        uint256 amount
    ) external view returns (uint256);
}

interface IUnilendV2Position {
    function newPosition(address _pool, address _recipient)
        external
        returns (uint256 nftID);

    function ownerOf(uint256 tokenId) external view returns (address owner);

    function getNftId(address _pool, address _user)
        external
        view
        returns (uint256 nftID);
}

interface IUnilendV2Pool {
    function setLTV(uint8 _number) external;

    function setLB(uint8 _number) external;

    function setRF(uint8 _number) external;

    function setInterestRateAddress(address _address) external;

    function accrueInterest() external;

    function lend(uint256 _nftID, int256 amount) external returns (uint256);

    function redeem(
        uint256 _nftID,
        int256 tok_amount,
        address _receiver
    ) external returns (int256);

    function redeemUnderlying(
        uint256 _nftID,
        int256 amount,
        address _receiver
    ) external returns (int256);

    function borrow(
        uint256 _nftID,
        int256 amount,
        address payable _recipient
    ) external;

    function repay(
        uint256 _nftID,
        int256 amount,
        address payer
    ) external returns (int256);

    function liquidate(
        uint256 _nftID,
        int256 amount,
        address _receiver,
        uint256 _toNftID
    ) external returns (int256);

    function liquidateMulti(
        uint256[] calldata _nftIDs,
        int256[] calldata amount,
        address _receiver,
        uint256 _toNftID
    ) external returns (int256);

    function processFlashLoan(address _receiver, int256 _amount) external;

    function transferFlashLoanProtocolFee(
        address _distributorAddress,
        address _token,
        uint256 _amount
    ) external;

    function init(
        address _token0,
        address _token1,
        address _interestRate,
        uint8 _ltv,
        uint8 _lb,
        uint8 _rf
    ) external;

    function getLTV() external view returns (uint256);

    function getLB() external view returns (uint256);

    function getRF() external view returns (uint256);

    function userBalanceOftoken0(uint256 _nftID)
        external
        view
        returns (uint256 _lendBalance0, uint256 _borrowBalance0);

    function userBalanceOftoken1(uint256 _nftID)
        external
        view
        returns (uint256 _lendBalance1, uint256 _borrowBalance1);

    function userBalanceOftokens(uint256 _nftID)
        external
        view
        returns (
            uint256 _lendBalance0,
            uint256 _borrowBalance0,
            uint256 _lendBalance1,
            uint256 _borrowBalance1
        );

    function userSharesOftoken0(uint256 _nftID)
        external
        view
        returns (uint256 _lendShare0, uint256 _borrowShare0);

    function userSharesOftoken1(uint256 _nftID)
        external
        view
        returns (uint256 _lendShare1, uint256 _borrowShare1);

    function userSharesOftokens(uint256 _nftID)
        external
        view
        returns (
            uint256 _lendShare0,
            uint256 _borrowShare0,
            uint256 _lendShare1,
            uint256 _borrowShare1
        );

    function userHealthFactor(uint256 _nftID)
        external
        view
        returns (uint256 _healthFactor0, uint256 _healthFactor1);

    function getAvailableLiquidity0()
        external
        view
        returns (uint256 _available);

    function getAvailableLiquidity1()
        external
        view
        returns (uint256 _available);
}

contract UnilendV2Core is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public governor;
    address public defaultInterestRate;
    address public poolMasterAddress;
    address payable public distributorAddress;
    address public oracleAddress;
    address public positionsAddress;

    uint256 public poolLength;

    uint256 private FLASHLOAN_FEE_TOTAL = 5;
    uint256 private FLASHLOAN_FEE_PROTOCOL = 3000;

    uint8 private default_LTV = 70;
    uint8 private default_LB = 10;
    uint8 private default_RF = 10;

    mapping(address => mapping(address => address)) public getPool;
    mapping(address => poolTokens) private Pool;

    struct poolTokens {
        address token0;
        address token1;
    }

    constructor(address _poolMasterAddress) {
        require(_poolMasterAddress != address(0), "UnilendV2: ZERO ADDRESS");
        governor = msg.sender;
        poolMasterAddress = _poolMasterAddress;
    }

    event PoolCreated(
        address indexed token0,
        address indexed token1,
        address pool,
        uint256
    );

    /**
     * @dev emitted when a flashloan is executed
     * @param _target the address of the flashLoanReceiver
     * @param _reserve the address of the reserve
     * @param _amount the amount requested
     * @param _totalFee the total fee on the amount
     * @param _protocolFee the part of the fee for the protocol
     * @param _timestamp the timestamp of the action
     **/
    event FlashLoan(
        address indexed _target,
        address indexed _reserve,
        int256 _amount,
        uint256 _totalFee,
        uint256 _protocolFee,
        uint256 _timestamp
    );

    event NewDefaultMarketConfig(uint8 _ltv, uint8 _lb, uint8 _rf);
    event NewDefaultInterestRateAddress(address indexed _address);
    event NewGovernorAddress(address indexed _address);
    event NewPositionAddress(address indexed _address);
    event NewOracleAddress(address indexed _address);

    modifier onlyGovernor() {
        require(governor == msg.sender, "The caller must be a governor");
        _;
    }

    /**
     * @dev functions affected by this modifier can only be invoked if the provided _amount input parameter
     * is not zero.
     * @param _amount the amount provided
     **/
    modifier onlyAmountNotZero(int256 _amount) {
        require(_amount != 0, "Amount must not be 0");
        _;
    }

    receive() external payable {}

    /**
     * @dev returns the fee applied to a flashloan and the portion to redirect to the protocol, in basis points.
     **/
    function getFlashLoanFeesInBips() public view returns (uint256, uint256) {
        return (FLASHLOAN_FEE_TOTAL, FLASHLOAN_FEE_PROTOCOL);
    }

    function getOraclePrice(
        address _token0,
        address _token1,
        uint256 _amount
    ) public view returns (uint256) {
        return
            IUnilendV2Oracle(oracleAddress).getAssetPrice(
                _token1,
                _token0,
                _amount
            );
    }

    function getPoolLTV(address _pool) public view returns (uint256 _ltv) {
        (address _token0, ) = getPoolTokens(_pool);
        if (_token0 != address(0)) {
            _ltv = IUnilendV2Pool(_pool).getLTV();
        }
    }

    function getPoolTokens(address _pool)
        public
        view
        returns (address, address)
    {
        poolTokens memory pt = Pool[_pool];
        return (pt.token0, pt.token1);
    }

    function getPoolByTokens(address _token0, address _token1)
        public
        view
        returns (address)
    {
        return getPool[_token0][_token1];
    }

    function balanceOfUserToken0(address _pool, address _address)
        external
        view
        returns (uint256 _lendBalance0, uint256 _borrowBalance0)
    {
        (address _token0, ) = getPoolTokens(_pool);
        if (_token0 != address(0)) {
            uint256 _nftID = IUnilendV2Position(positionsAddress).getNftId(
                _pool,
                _address
            );
            if (_nftID > 0) {
                (_lendBalance0, _borrowBalance0) = IUnilendV2Pool(_pool)
                    .userBalanceOftoken0(_nftID);
            }
        }
    }

    function balanceOfUserToken1(address _pool, address _address)
        external
        view
        returns (uint256 _lendBalance1, uint256 _borrowBalance1)
    {
        (address _token0, ) = getPoolTokens(_pool);
        if (_token0 != address(0)) {
            uint256 _nftID = IUnilendV2Position(positionsAddress).getNftId(
                _pool,
                _address
            );
            if (_nftID > 0) {
                (_lendBalance1, _borrowBalance1) = IUnilendV2Pool(_pool)
                    .userBalanceOftoken1(_nftID);
            }
        }
    }

    function balanceOfUserTokens(address _pool, address _address)
        external
        view
        returns (
            uint256 _lendBalance0,
            uint256 _borrowBalance0,
            uint256 _lendBalance1,
            uint256 _borrowBalance1
        )
    {
        (address _token0, ) = getPoolTokens(_pool);
        if (_token0 != address(0)) {
            uint256 _nftID = IUnilendV2Position(positionsAddress).getNftId(
                _pool,
                _address
            );
            if (_nftID > 0) {
                (
                    _lendBalance0,
                    _borrowBalance0,
                    _lendBalance1,
                    _borrowBalance1
                ) = IUnilendV2Pool(_pool).userBalanceOftokens(_nftID);
            }
        }
    }

    function shareOfUserToken0(address _pool, address _address)
        external
        view
        returns (uint256 _lendShare0, uint256 _borrowShare0)
    {
        (address _token0, ) = getPoolTokens(_pool);
        if (_token0 != address(0)) {
            uint256 _nftID = IUnilendV2Position(positionsAddress).getNftId(
                _pool,
                _address
            );
            if (_nftID > 0) {
                (_lendShare0, _borrowShare0) = IUnilendV2Pool(_pool)
                    .userSharesOftoken0(_nftID);
            }
        }
    }

    function shareOfUserToken1(address _pool, address _address)
        external
        view
        returns (uint256 _lendShare1, uint256 _borrowShare1)
    {
        (address _token0, ) = getPoolTokens(_pool);
        if (_token0 != address(0)) {
            uint256 _nftID = IUnilendV2Position(positionsAddress).getNftId(
                _pool,
                _address
            );
            if (_nftID > 0) {
                (_lendShare1, _borrowShare1) = IUnilendV2Pool(_pool)
                    .userSharesOftoken1(_nftID);
            }
        }
    }

    function shareOfUserTokens(address _pool, address _address)
        external
        view
        returns (
            uint256 _lendShare0,
            uint256 _borrowShare0,
            uint256 _lendShare1,
            uint256 _borrowShare1
        )
    {
        (address _token0, ) = getPoolTokens(_pool);
        if (_token0 != address(0)) {
            uint256 _nftID = IUnilendV2Position(positionsAddress).getNftId(
                _pool,
                _address
            );
            if (_nftID > 0) {
                (
                    _lendShare0,
                    _borrowShare0,
                    _lendShare1,
                    _borrowShare1
                ) = IUnilendV2Pool(_pool).userSharesOftokens(_nftID);
            }
        }
    }

    function getUserHealthFactor(address _pool, address _address)
        external
        view
        returns (uint256 _healthFactor0, uint256 _healthFactor1)
    {
        (address _token0, ) = getPoolTokens(_pool);
        if (_token0 != address(0)) {
            uint256 _nftID = IUnilendV2Position(positionsAddress).getNftId(
                _pool,
                _address
            );
            if (_nftID > 0) {
                (_healthFactor0, _healthFactor1) = IUnilendV2Pool(_pool)
                    .userHealthFactor(_nftID);
            }
        }
    }

    function getPoolAvailableLiquidity(address _pool)
        external
        view
        returns (uint256 _token0Liquidity, uint256 _token1Liquidity)
    {
        (address _token0, ) = getPoolTokens(_pool);
        if (_token0 != address(0)) {
            _token0Liquidity = IUnilendV2Pool(_pool).getAvailableLiquidity0();
            _token1Liquidity = IUnilendV2Pool(_pool).getAvailableLiquidity1();
        }
    }

    function setDefaultMarketConfig(
        uint8 _ltv,
        uint8 _lb,
        uint8 _rf
    ) external onlyGovernor {
        require(_ltv > 0 && _ltv < 99, "UnilendV2: INVALID RANGE");
        require(_lb > 0 && _lb < (100 - _ltv), "UnilendV2: INVALID RANGE");
        require(_rf > 0 && _rf < 90, "UnilendV2: INVALID RANGE");

        default_LTV = _ltv;
        default_LB = _lb;
        default_RF = _rf;

        emit NewDefaultMarketConfig(_ltv, _lb, _rf);
    }

    function setPoolLTV(address _pool, uint8 _number) external onlyGovernor {
        require(_number > 0 && _number < 99, "UnilendV2: INVALID RANGE");

        (address _token0, ) = getPoolTokens(_pool);
        if (_token0 != address(0)) {
            IUnilendV2Pool(_pool).setLTV(_number);
        }
    }

    function setPoolLB(address _pool, uint8 _number) external onlyGovernor {
        require(_number > 0 && _number < 99, "UnilendV2: INVALID RANGE");

        (address _token0, ) = getPoolTokens(_pool);
        if (_token0 != address(0)) {
            IUnilendV2Pool(_pool).setLB(_number);
        }
    }

    function setPoolRF(address _pool, uint8 _number) external onlyGovernor {
        require(_number > 0 && _number < 99, "UnilendV2: INVALID RANGE");

        (address _token0, ) = getPoolTokens(_pool);
        if (_token0 != address(0)) {
            IUnilendV2Pool(_pool).setRF(_number);
        }
    }

    function setPoolInterestRateAddress(address _pool, address _address)
        external
        onlyGovernor
    {
        require(_address != address(0), "UnilendV2: ZERO ADDRESS");

        (address _token0, ) = getPoolTokens(_pool);
        if (_token0 != address(0)) {
            IUnilendV2Pool(_pool).setInterestRateAddress(_address);
        }
    }

    function setDefaultInterestRateAddress(address _address)
        external
        onlyGovernor
    {
        require(_address != address(0), "UnilendV2: ZERO ADDRESS");
        defaultInterestRate = _address;

        emit NewDefaultInterestRateAddress(_address);
    }

    /**
     * @dev set new admin for contract.
     * @param _address the address of new governor
     **/
    function setGovernor(address _address) external onlyGovernor {
        require(_address != address(0), "UnilendV2: ZERO ADDRESS");
        governor = _address;

        emit NewGovernorAddress(_address);
    }

    function setPositionAddress(address _address) external onlyGovernor {
        require(_address != address(0), "UnilendV2: ZERO ADDRESS");
        require(
            positionsAddress == address(0),
            "UnilendV2: Position Address Already Set"
        );
        positionsAddress = _address;

        emit NewPositionAddress(_address);
    }

    /**
     * @dev set new oracle address.
     * @param _address new address
     **/
    function setOracleAddress(address _address) external onlyGovernor {
        require(_address != address(0), "UnilendV2: ZERO ADDRESS");
        oracleAddress = _address;

        emit NewOracleAddress(_address);
    }

    /**
     * @dev set new distributor address.
     * @param _address new address
     **/
    function setDistributorAddress(address payable _address)
        external
        onlyGovernor
    {
        require(_address != address(0), "UnilendV2: ZERO ADDRESS");
        distributorAddress = _address;
    }

    /**
     * @dev set new flash loan fees.
     * @param _newFeeTotal total fee
     * @param _newFeeProtocol protocol fee
     **/
    function setFlashLoanFeesInBips(
        uint256 _newFeeTotal,
        uint256 _newFeeProtocol
    ) external onlyGovernor returns (bool) {
        require(
            _newFeeTotal > 0 && _newFeeTotal < 10000,
            "UnilendV1: INVALID TOTAL FEE RANGE"
        );
        require(
            _newFeeProtocol > 0 && _newFeeProtocol < 10000,
            "UnilendV1: INVALID PROTOCOL FEE RANGE"
        );

        FLASHLOAN_FEE_TOTAL = _newFeeTotal;
        FLASHLOAN_FEE_PROTOCOL = _newFeeProtocol;

        return true;
    }

    function transferFlashLoanProtocolFeeInternal(
        address _pool,
        address _token,
        uint256 _amount
    ) internal {
        if (distributorAddress != address(0)) {
            IUnilendV2Pool(_pool).transferFlashLoanProtocolFee(
                distributorAddress,
                _token,
                _amount
            );
        }
    }

    /**
     * @dev allows smartcontracts to access the liquidity of the pool within one transaction,
     * as long as the amount taken plus a fee is returned. NOTE There are security concerns for developers of flashloan receiver contracts
     * that must be kept into consideration.
     * @param _receiver The address of the contract receiving the funds. The receiver should implement the IFlashLoanReceiver interface.
     * @param _pool the address of the principal reserve pool
     * @param _amount the amount requested for this flashloan
     **/
    function flashLoan(
        address _receiver,
        address _pool,
        int256 _amount,
        bytes calldata _params
    ) external nonReentrant {
        (address _token0, address _token1) = getPoolTokens(_pool);
        require(_token0 != address(0), "UnilendV2: POOL NOT FOUND");

        address _reserve = _amount < 0 ? _token0 : _token1;
        uint256 _amountU = _amount < 0 ? uint256(-_amount) : uint256(_amount);

        //check that the reserve has enough available liquidity
        uint256 availableLiquidityBefore = IERC20(_reserve).balanceOf(_pool);

        require(
            availableLiquidityBefore >= _amountU,
            "There is not enough liquidity available to borrow"
        );

        (
            uint256 totalFeeBips,
            uint256 protocolFeeBips
        ) = getFlashLoanFeesInBips();
        //calculate amount fee
        uint256 amountFee = _amountU.mul(totalFeeBips).div(10000);

        //protocol fee is the part of the amountFee reserved for the protocol - the rest goes to depositors
        uint256 protocolFee = amountFee.mul(protocolFeeBips).div(10000);
        require(
            amountFee > 0 && protocolFee > 0,
            "The requested amount is too small for a flashLoan."
        );

        IUnilendV2Pool(_pool).processFlashLoan(_receiver, _amount);

        IFlashLoanReceiver(_receiver).executeOperation(
            _reserve,
            _amountU,
            amountFee,
            _params
        );

        //check that the actual balance of the core contract includes the returned amount
        uint256 availableLiquidityAfter = IERC20(_reserve).balanceOf(_pool);

        require(
            availableLiquidityAfter == availableLiquidityBefore.add(amountFee),
            "The actual balance of the protocol is inconsistent"
        );

        transferFlashLoanProtocolFeeInternal(_pool, _reserve, protocolFee);

        // solium-disable-next-line
        emit FlashLoan(
            _receiver,
            _reserve,
            _amount,
            amountFee,
            protocolFee,
            block.timestamp
        );
    }

    /**
     * @dev deposits The underlying asset into the reserve.
     * @param _pool the address of the pool
     * @param _amount the amount to be deposited
     **/
    function lend(address _pool, int256 _amount)
        external
        onlyAmountNotZero(_amount)
        nonReentrant
        returns (uint256 mintedTokens)
    {
        (address _token0, address _token1) = getPoolTokens(_pool);
        require(_token0 != address(0), "UnilendV2: POOL NOT FOUND");

        uint256 _nftID = IUnilendV2Position(positionsAddress).getNftId(
            _pool,
            msg.sender
        );
        if (_nftID == 0) {
            _nftID = IUnilendV2Position(positionsAddress).newPosition(
                _pool,
                msg.sender
            );
        }

        address _reserve = _amount < 0 ? _token0 : _token1;
        mintedTokens = iLend(_pool, _reserve, _amount, _nftID);
    }

    function iLend(
        address _pool,
        address _token,
        int256 _amount,
        uint256 _nftID
    ) internal returns (uint256 mintedTokens) {
        address _user = msg.sender;
        IUnilendV2Pool(_pool).accrueInterest();

        if (_amount < 0) {
            uint256 reserveBalance = IERC20(_token).balanceOf(_pool);
            IERC20(_token).safeTransferFrom(_user, _pool, uint256(-_amount));
            _amount = -int256(
                (IERC20(_token).balanceOf(_pool)).sub(reserveBalance)
            );
        }

        if (_amount > 0) {
            uint256 reserveBalance = IERC20(_token).balanceOf(_pool);
            IERC20(_token).safeTransferFrom(_user, _pool, uint256(_amount));
            _amount = int256(
                (IERC20(_token).balanceOf(_pool)).sub(reserveBalance)
            );
        }

        mintedTokens = IUnilendV2Pool(_pool).lend(_nftID, _amount);
    }

    /**
     * @dev Redeems the uTokens for underlying assets.
     * @param _pool the address of the pool
     * @param _token_amount the amount to be redeemed
     **/
    function redeem(
        address _pool,
        int256 _token_amount,
        address _receiver
    ) external nonReentrant returns (int256 redeemTokens) {
        (address _token0, ) = getPoolTokens(_pool);
        require(_token0 != address(0), "UnilendV2: POOL NOT FOUND");

        uint256 _nftID = IUnilendV2Position(positionsAddress).getNftId(
            _pool,
            msg.sender
        );
        require(_nftID > 0, "UnilendV2: POSITION NOT FOUND");

        redeemTokens = IUnilendV2Pool(_pool).redeem(
            _nftID,
            _token_amount,
            _receiver
        );
    }

    /**
     * @dev Redeems the underlying amount of assets.
     * @param _pool the address of the pool
     * @param _amount the amount to be redeemed
     **/
    function redeemUnderlying(
        address _pool,
        int256 _amount,
        address _receiver
    )
        external
        onlyAmountNotZero(_amount)
        nonReentrant
        returns (int256 _token_amount)
    {
        (address _token0, ) = getPoolTokens(_pool);
        require(_token0 != address(0), "UnilendV2: POOL NOT FOUND");

        uint256 _nftID = IUnilendV2Position(positionsAddress).getNftId(
            _pool,
            msg.sender
        );
        require(_nftID > 0, "UnilendV2: POSITION NOT FOUND");

        _token_amount = IUnilendV2Pool(_pool).redeemUnderlying(
            _nftID,
            _amount,
            _receiver
        );
    }

    function borrow(
        address _pool,
        int256 _amount,
        uint256 _collateral_amount,
        address payable _recipient
    ) external onlyAmountNotZero(_amount) nonReentrant {
        (address _token0, address _token1) = getPoolTokens(_pool);
        require(_token0 != address(0), "UnilendV2: POOL NOT FOUND");

        IUnilendV2Pool _poolContract = IUnilendV2Pool(_pool);
        address _user = msg.sender;

        uint256 _nftID = IUnilendV2Position(positionsAddress).getNftId(
            _pool,
            _user
        );
        if (_nftID == 0) {
            _nftID = IUnilendV2Position(positionsAddress).newPosition(
                _pool,
                _user
            );
        }

        if (_amount < 0) {
            require(
                _poolContract.getAvailableLiquidity0() >= uint256(-_amount),
                "There is not enough liquidity0 available to borrow"
            );

            // lend collateral
            if (_collateral_amount > 0) {
                iLend(_pool, _token1, int256(_collateral_amount), _nftID);
            }
        }

        if (_amount > 0) {
            require(
                _poolContract.getAvailableLiquidity1() >= uint256(_amount),
                "There is not enough liquidity1 available to borrow"
            );

            // lend collateral
            if (_collateral_amount > 0) {
                iLend(_pool, _token0, -int256(_collateral_amount), _nftID);
            }
        }

        _poolContract.borrow(_nftID, _amount, _recipient);
    }

    function repay(
        address _pool,
        int256 _amount,
        address _for
    )
        external
        onlyAmountNotZero(_amount)
        nonReentrant
        returns (int256 _retAmount)
    {
        (address _token0, address _token1) = getPoolTokens(_pool);
        require(_token0 != address(0), "UnilendV2: POOL NOT FOUND");

        IUnilendV2Pool _poolContract = IUnilendV2Pool(_pool);
        address _user = msg.sender;

        uint256 _nftID = IUnilendV2Position(positionsAddress).getNftId(
            _pool,
            _for
        );
        require(_nftID > 0, "UnilendV2: POSITION NOT FOUND");

        _retAmount = _poolContract.repay(_nftID, _amount, _user);

        if (_retAmount < 0) {
            IERC20(_token0).safeTransferFrom(
                _user,
                _pool,
                uint256(-_retAmount)
            );
        }

        if (_retAmount > 0) {
            IERC20(_token1).safeTransferFrom(_user, _pool, uint256(_retAmount));
        }
    }

    function liquidate(
        address _pool,
        address _for,
        int256 _amount,
        address _receiver,
        bool uPosition
    )
        external
        onlyAmountNotZero(_amount)
        nonReentrant
        returns (int256 payAmount)
    {
        (address _token0, address _token1) = getPoolTokens(_pool);
        require(_token0 != address(0), "UnilendV2: POOL NOT FOUND");

        IUnilendV2Pool _poolContract = IUnilendV2Pool(_pool);
        address _user = msg.sender;

        uint256 _nftID = IUnilendV2Position(positionsAddress).getNftId(
            _pool,
            _for
        );
        require(_nftID > 0, "UnilendV2: POSITION NOT FOUND");

        if (uPosition) {
            uint256 _toNftID = IUnilendV2Position(positionsAddress).getNftId(
                _pool,
                _receiver
            );
            if (_toNftID == 0) {
                _toNftID = IUnilendV2Position(positionsAddress).newPosition(
                    _pool,
                    _receiver
                );
            }

            payAmount = _poolContract.liquidate(
                _nftID,
                _amount,
                _receiver,
                _toNftID
            );
        } else {
            payAmount = _poolContract.liquidate(_nftID, _amount, _receiver, 0);
        }

        if (payAmount < 0) {
            IERC20(_token0).safeTransferFrom(_user, _pool, uint256(-payAmount));
        }

        if (payAmount > 0) {
            IERC20(_token1).safeTransferFrom(_user, _pool, uint256(payAmount));
        }
    }

    function liquidateMulti(
        address _pool,
        uint256[] calldata _nftIDs,
        int256[] calldata _amounts,
        address _receiver,
        bool uPosition
    ) external nonReentrant returns (int256 payAmount) {
        (address _token0, address _token1) = getPoolTokens(_pool);
        require(_token0 != address(0), "UnilendV2: POOL NOT FOUND");
        require(
            _nftIDs.length == _amounts.length,
            "UnilendV2: INVALID ARRAY LENGTH"
        );

        IUnilendV2Pool _poolContract = IUnilendV2Pool(_pool);
        address _user = msg.sender;

        if (uPosition) {
            uint256 _toNftID = IUnilendV2Position(positionsAddress).getNftId(
                _pool,
                _receiver
            );
            if (_toNftID == 0) {
                _toNftID = IUnilendV2Position(positionsAddress).newPosition(
                    _pool,
                    _receiver
                );
            }

            payAmount = _poolContract.liquidateMulti(
                _nftIDs,
                _amounts,
                _receiver,
                _toNftID
            );
        } else {
            payAmount = _poolContract.liquidateMulti(
                _nftIDs,
                _amounts,
                _receiver,
                0
            );
        }

        if (payAmount < 0) {
            IERC20(_token0).safeTransferFrom(_user, _pool, uint256(-payAmount));
        }

        if (payAmount > 0) {
            IERC20(_token1).safeTransferFrom(_user, _pool, uint256(payAmount));
        }
    }

    /**
     * @dev Creates pool for assets.
     * This function is executed by the overlying uToken contract.
     * @param _tokenA the address of the token0
     * @param _tokenB the address of the token1
     **/
    function createPool(address _tokenA, address _tokenB)
        public
        returns (address)
    {
        (address token0, address token1) = _tokenA < _tokenB
            ? (_tokenA, _tokenB)
            : (_tokenB, _tokenA);
        require(_tokenA != address(0), "UnilendV2: ZERO ADDRESS");
        require(_tokenA != _tokenB, "UnilendV2: IDENTICAL ADDRESSES");
        require(
            getPool[token0][token1] == address(0),
            "UnilendV2: POOL ALREADY CREATED"
        );

        address _poolNft;
        bytes20 targetBytes = bytes20(poolMasterAddress);

        require(
            IERC20Metadata(token0).totalSupply() > 0,
            "UnilendV2: INVALID ERC20 TOKEN"
        );
        require(
            IERC20Metadata(token1).totalSupply() > 0,
            "UnilendV2: INVALID ERC20 TOKEN"
        );

        /*
            This appears to be Solidity assembly code. It looks like it is defining a contract factory function that creates a new contract and stores it in a variable called _poolNft.
            The code first loads the memory location at address 0x40 into the clone variable. It then stores a hexadecimal value at that memory location. The hexadecimal value appears to be the bytecode of a contract. 
            The code then stores the value of targetBytes at an offset of 0x14 relative to the clone memory location, and stores another hexadecimal value at an offset of 0x28 relative to the clone memory location.
            Finally, the code calls the create function, passing in 0 as the first argument, the clone variable as the second argument, and 0x37 as the third argument.
            The create function is a built-in Solidity function that creates a new contract using the provided bytecode and returns the contract's address. The returned contract address is stored in the _poolNft variable.
         */

        assembly {
            let clone := mload(0x40)
            mstore(
                clone,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone, 0x14), targetBytes)
            mstore(
                add(clone, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            _poolNft := create(0, clone, 0x37)
        }

        address _poolAddress = address(_poolNft);

        IUnilendV2Pool(_poolAddress).init(
            token0,
            token1,
            defaultInterestRate,
            default_LTV,
            default_LB,
            default_RF
        );

        poolTokens storage pt = Pool[_poolAddress];
        pt.token0 = token0;
        pt.token1 = token1;

        getPool[token0][token1] = _poolAddress;
        getPool[token1][token0] = _poolAddress; // populate mapping in the reverse direction

        poolLength++;

        emit PoolCreated(token0, token1, _poolAddress, poolLength);

        return _poolAddress;
    }
}
