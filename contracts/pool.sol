// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "./lib/utils/math/SafeMath.sol";
import "./lib/token/ERC20/utils/SafeERC20.sol";
import "./lib/security/ReentrancyGuard.sol";
import "./lib/utils/Counters.sol";

library MathEx {
    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x < y ? x : y;
    }

    // babylonian method (https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method)
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}

contract UnilendV2library {
    using SafeMath for uint256;

    function priceScaled(uint256 _price) internal pure returns (uint256) {
        uint256 _length = 0;
        uint256 tempI = _price;
        while (tempI != 0) {
            tempI = tempI / 10;
            _length++;
        }

        _length = _length.sub(3);
        return (_price.div(10**_length)).mul(10**_length);
    }

    function calculateShare(
        uint256 _totalShares,
        uint256 _totalAmount,
        uint256 _amount
    ) internal pure returns (uint256) {
        if (_totalShares == 0) {
            return MathEx.sqrt(_amount.mul(_amount));
        } else {
            return (_amount).mul(_totalShares).div(_totalAmount);
        }
    }

    function getShareValue(
        uint256 _totalAmount,
        uint256 _totalSupply,
        uint256 _amount
    ) internal pure returns (uint256) {
        return (_amount.mul(_totalAmount)).div(_totalSupply);
    }

    function getShareByValue(
        uint256 _totalAmount,
        uint256 _totalSupply,
        uint256 _valueAmount
    ) internal pure returns (uint256) {
        return (_valueAmount.mul(_totalSupply)).div(_totalAmount);
    }

    function calculateInterest(
        uint256 _principal,
        uint256 _rate,
        uint256 _duration
    ) internal pure returns (uint256) {
        return _principal.mul(_rate.mul(_duration)).div(10**20);
    }
}

contract UnilendV2transfer {
    using SafeERC20 for IERC20;

    address public token0;
    address public token1;
    address payable public core;

    modifier onlyCore() {
        require(core == msg.sender, "Not Permitted");
        _;
    }

    /**
     * @dev transfers to the user a specific amount from the reserve.
     * @param _reserve the address of the reserve where the transfer is happening
     * @param _user the address of the user receiving the transfer
     * @param _amount the amount being transferred
     **/
    function transferToUser(
        address _reserve,
        address payable _user,
        uint256 _amount
    ) internal {
        require(_user != address(0), "UnilendV1: USER ZERO ADDRESS");

        IERC20(_reserve).safeTransfer(_user, _amount);
    }
}

interface IUnilendV2Core {
    function getOraclePrice(
        address _token0,
        address _token1,
        uint256 _amount
    ) external view returns (uint256);
}

interface IUnilendV2InterestRateModel {
    function getCurrentInterestRate(
        uint256 totalBorrow,
        uint256 availableBorrow
    ) external pure returns (uint256);
}

contract UnilendV2Pool is UnilendV2library, UnilendV2transfer {
    using SafeMath for uint256;

    bool initialized;
    address public interestRateAddress;
    uint256 public lastUpdated;

    uint8 ltv; // loan to value
    uint8 lb; // liquidation bonus
    uint8 rf; // reserve factor
    uint64 public constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1e18;

    tM public token0Data;
    tM public token1Data;
    mapping(uint256 => pM) public positionData;

    struct pM {
        uint256 token0lendShare;
        uint256 token1lendShare;
        uint256 token0borrowShare;
        uint256 token1borrowShare;
    }

    struct tM {
        uint256 totalLendShare;
        uint256 totalBorrowShare;
        uint256 totalBorrow;
    }

    // /**
    // * @dev emitted on lend
    // * @param _positionID the id of position NFT
    // * @param _amount the amount to be deposited for token
    // * @param _timestamp the timestamp of the action
    // **/
    event Lend(
        address indexed _asset,
        uint256 indexed _positionID,
        uint256 _amount,
        uint256 _token_amount
    );
    event Redeem(
        address indexed _asset,
        uint256 indexed _positionID,
        uint256 _token_amount,
        uint256 _amount
    );
    event InterestUpdate(
        uint256 _newRate0,
        uint256 _newRate1,
        uint256 totalBorrows0,
        uint256 totalBorrows1
    );
    event Borrow(
        address indexed _asset,
        uint256 indexed _positionID,
        uint256 _amount,
        uint256 totalBorrows,
        address _recipient
    );
    event RepayBorrow(
        address indexed _asset,
        uint256 indexed _positionID,
        uint256 _amount,
        uint256 totalBorrows,
        address _payer
    );
    event LiquidateBorrow(
        address indexed _asset,
        uint256 indexed _positionID,
        uint256 indexed _toPositionID,
        uint256 repayAmount,
        uint256 seizeTokens
    );
    event LiquidationPriceUpdate(
        uint256 indexed _positionID,
        uint256 _price,
        uint256 _last_price,
        uint256 _amount
    );

    event NewMarketInterestRateModel(
        address oldInterestRateModel,
        address newInterestRateModel
    );
    event NewLTV(uint256 oldLTV, uint256 newLTV);
    event NewLB(uint256 oldLB, uint256 newLB);
    event NewRF(uint256 oldRF, uint256 newRF);

    constructor() {
        core = payable(msg.sender);
    }

    function init(
        address _token0,
        address _token1,
        address _interestRate,
        uint8 _ltv,
        uint8 _lb,
        uint8 _rf
    ) external {
        require(!initialized, "UnilendV2: POOL ALREADY INIT");

        initialized = true;

        token0 = _token0;
        token1 = _token1;
        interestRateAddress = _interestRate;
        core = payable(msg.sender);

        ltv = _ltv;
        lb = _lb;
        rf = _rf;
    }

    function getLTV() external view returns (uint256) {
        return ltv;
    }

    function getLB() external view returns (uint256) {
        return lb;
    }

    function getRF() external view returns (uint256) {
        return rf;
    }

    function checkHealthFactorLtv(uint256 _nftID) internal view {
        (uint256 _healthFactor0, uint256 _healthFactor1) = userHealthFactorLtv(
            _nftID
        );
        require(
            _healthFactor0 > HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
            "Low Ltv HealthFactor0"
        );
        require(
            _healthFactor1 > HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
            "Low Ltv HealthFactor1"
        );
    }

    function getInterestRate(uint256 _totalBorrow, uint256 _availableBorrow)
        public
        view
        returns (uint256)
    {
        return
            IUnilendV2InterestRateModel(interestRateAddress)
                .getCurrentInterestRate(_totalBorrow, _availableBorrow);
    }

    function getAvailableLiquidity0() public view returns (uint256 _available) {
        tM memory _tm0 = token0Data;

        uint256 totalBorrow = _tm0.totalBorrow;
        uint256 totalLiq = totalBorrow.add(
            IERC20(token0).balanceOf(address(this))
        );
        uint256 maxAvail = (totalLiq.mul(uint256(100).sub(rf))).div(100);

        if (maxAvail > totalBorrow) {
            _available = maxAvail.sub(totalBorrow);
        }
    }

    function getAvailableLiquidity1() public view returns (uint256 _available) {
        tM memory _tm1 = token1Data;

        uint256 totalBorrow = _tm1.totalBorrow;
        uint256 totalLiq = totalBorrow.add(
            IERC20(token1).balanceOf(address(this))
        );
        uint256 maxAvail = (totalLiq.mul(uint256(100).sub(rf))).div(100);

        if (maxAvail > totalBorrow) {
            _available = maxAvail.sub(totalBorrow);
        }
    }

    function userHealthFactorLtv(uint256 _nftID)
        public
        view
        returns (uint256 _healthFactor0, uint256 _healthFactor1)
    {
        (uint256 _lendBalance0, uint256 _borrowBalance0) = userBalanceOftoken0(
            _nftID
        );
        (uint256 _lendBalance1, uint256 _borrowBalance1) = userBalanceOftoken1(
            _nftID
        );

        if (_borrowBalance0 == 0) {
            _healthFactor0 = type(uint256).max;
        } else {
            uint256 collateralBalance = IUnilendV2Core(core).getOraclePrice(
                token1,
                token0,
                _lendBalance1
            );
            _healthFactor0 = (collateralBalance.mul(ltv).mul(1e18).div(100))
                .div(_borrowBalance0);
        }

        if (_borrowBalance1 == 0) {
            _healthFactor1 = type(uint256).max;
        } else {
            uint256 collateralBalance = IUnilendV2Core(core).getOraclePrice(
                token0,
                token1,
                _lendBalance0
            );
            _healthFactor1 = (collateralBalance.mul(ltv).mul(1e18).div(100))
                .div(_borrowBalance1);
        }
    }

    function userHealthFactor(uint256 _nftID)
        public
        view
        returns (uint256 _healthFactor0, uint256 _healthFactor1)
    {
        (uint256 _lendBalance0, uint256 _borrowBalance0) = userBalanceOftoken0(
            _nftID
        );
        (uint256 _lendBalance1, uint256 _borrowBalance1) = userBalanceOftoken1(
            _nftID
        );

        if (_borrowBalance0 == 0) {
            _healthFactor0 = type(uint256).max;
        } else {
            uint256 collateralBalance = IUnilendV2Core(core).getOraclePrice(
                token1,
                token0,
                _lendBalance1
            );
            _healthFactor0 = (
                collateralBalance.mul(uint256(100).sub(lb)).mul(1e18).div(100)
            ).div(_borrowBalance0);
        }

        if (_borrowBalance1 == 0) {
            _healthFactor1 = type(uint256).max;
        } else {
            uint256 collateralBalance = IUnilendV2Core(core).getOraclePrice(
                token0,
                token1,
                _lendBalance0
            );
            _healthFactor1 = (
                collateralBalance.mul(uint256(100).sub(lb)).mul(1e18).div(100)
            ).div(_borrowBalance1);
        }
    }

    function userBalanceOftoken0(uint256 _nftID)
        public
        view
        returns (uint256 _lendBalance0, uint256 _borrowBalance0)
    {
        pM memory _positionMt = positionData[_nftID];
        tM memory _tm0 = token0Data;

        uint256 _totalBorrow = _tm0.totalBorrow;
        if (block.number > lastUpdated) {
            uint256 interestRate0 = getInterestRate(
                _tm0.totalBorrow,
                getAvailableLiquidity0()
            );
            _totalBorrow = _totalBorrow.add(
                calculateInterest(
                    _tm0.totalBorrow,
                    interestRate0,
                    (block.number - lastUpdated)
                )
            );
        }

        if (_positionMt.token0lendShare > 0) {
            uint256 tokenBalance0 = IERC20(token0).balanceOf(address(this));
            uint256 _totTokenBalance0 = tokenBalance0.add(_totalBorrow);
            _lendBalance0 = getShareValue(
                _totTokenBalance0,
                _tm0.totalLendShare,
                _positionMt.token0lendShare
            );
        }

        if (_positionMt.token0borrowShare > 0) {
            _borrowBalance0 = getShareValue(
                _totalBorrow,
                _tm0.totalBorrowShare,
                _positionMt.token0borrowShare
            );
        }
    }

    function userBalanceOftoken1(uint256 _nftID)
        public
        view
        returns (uint256 _lendBalance1, uint256 _borrowBalance1)
    {
        pM memory _positionMt = positionData[_nftID];
        tM memory _tm1 = token1Data;

        uint256 _totalBorrow = _tm1.totalBorrow;
        if (block.number > lastUpdated) {
            uint256 interestRate1 = getInterestRate(
                _tm1.totalBorrow,
                getAvailableLiquidity1()
            );
            _totalBorrow = _totalBorrow.add(
                calculateInterest(
                    _tm1.totalBorrow,
                    interestRate1,
                    (block.number - lastUpdated)
                )
            );
        }

        if (_positionMt.token1lendShare > 0) {
            uint256 tokenBalance1 = IERC20(token1).balanceOf(address(this));
            uint256 _totTokenBalance1 = tokenBalance1.add(_totalBorrow);
            _lendBalance1 = getShareValue(
                _totTokenBalance1,
                _tm1.totalLendShare,
                _positionMt.token1lendShare
            );
        }

        if (_positionMt.token1borrowShare > 0) {
            _borrowBalance1 = getShareValue(
                _totalBorrow,
                _tm1.totalBorrowShare,
                _positionMt.token1borrowShare
            );
        }
    }

    function userBalanceOftokens(uint256 _nftID)
        public
        view
        returns (
            uint256 _lendBalance0,
            uint256 _borrowBalance0,
            uint256 _lendBalance1,
            uint256 _borrowBalance1
        )
    {
        (_lendBalance0, _borrowBalance0) = userBalanceOftoken0(_nftID);
        (_lendBalance1, _borrowBalance1) = userBalanceOftoken1(_nftID);
    }

    function userSharesOftoken0(uint256 _nftID)
        public
        view
        returns (uint256 _lendShare0, uint256 _borrowShare0)
    {
        pM memory _positionMt = positionData[_nftID];

        return (_positionMt.token0lendShare, _positionMt.token0borrowShare);
    }

    function userSharesOftoken1(uint256 _nftID)
        public
        view
        returns (uint256 _lendShare1, uint256 _borrowShare1)
    {
        pM memory _positionMt = positionData[_nftID];

        return (_positionMt.token1lendShare, _positionMt.token1borrowShare);
    }

    function userSharesOftokens(uint256 _nftID)
        public
        view
        returns (
            uint256 _lendShare0,
            uint256 _borrowShare0,
            uint256 _lendShare1,
            uint256 _borrowShare1
        )
    {
        pM memory _positionMt = positionData[_nftID];

        return (
            _positionMt.token0lendShare,
            _positionMt.token0borrowShare,
            _positionMt.token1lendShare,
            _positionMt.token1borrowShare
        );
    }

    function poolData()
        external
        view
        returns (
            uint256 _totalLendShare0,
            uint256 _totalBorrowShare0,
            uint256 _totalBorrow0,
            uint256 _totalBalance0,
            uint256 _totalAvailableLiquidity0,
            uint256 _totalLendShare1,
            uint256 _totalBorrowShare1,
            uint256 _totalBorrow1,
            uint256 _totalBalance1,
            uint256 _totalAvailableLiquidity1
        )
    {
        tM storage _tm0 = token0Data;
        tM storage _tm1 = token1Data;

        return (
            _tm0.totalLendShare,
            _tm0.totalBorrowShare,
            _tm0.totalBorrow,
            IERC20(token0).balanceOf(address(this)),
            getAvailableLiquidity0(),
            _tm1.totalLendShare,
            _tm1.totalBorrowShare,
            _tm1.totalBorrow,
            IERC20(token1).balanceOf(address(this)),
            getAvailableLiquidity1()
        );
    }

    function setInterestRateAddress(address _address) public onlyCore {
        emit NewMarketInterestRateModel(interestRateAddress, _address);
        interestRateAddress = _address;
    }

    function setLTV(uint8 _number) public onlyCore {
        emit NewLTV(ltv, _number);
        ltv = _number;
    }

    function setLB(uint8 _number) public onlyCore {
        emit NewLB(lb, _number);
        lb = _number;
    }

    function setRF(uint8 _number) public onlyCore {
        emit NewRF(rf, _number);
        rf = _number;
    }

    function accrueInterest() public {
        uint256 remainingBlocks = block.number - lastUpdated;

        if (remainingBlocks > 0) {
            tM storage _tm0 = token0Data;
            tM storage _tm1 = token1Data;

            uint256 interestRate0 = getInterestRate(
                _tm0.totalBorrow,
                getAvailableLiquidity0()
            );
            uint256 interestRate1 = getInterestRate(
                _tm1.totalBorrow,
                getAvailableLiquidity1()
            );

            _tm0.totalBorrow = _tm0.totalBorrow.add(
                calculateInterest(
                    _tm0.totalBorrow,
                    interestRate0,
                    remainingBlocks
                )
            );
            _tm1.totalBorrow = _tm1.totalBorrow.add(
                calculateInterest(
                    _tm1.totalBorrow,
                    interestRate1,
                    remainingBlocks
                )
            );

            lastUpdated = block.number;

            emit InterestUpdate(
                interestRate0,
                interestRate1,
                _tm0.totalBorrow,
                _tm1.totalBorrow
            );
        }
    }

    function transferFlashLoanProtocolFee(
        address _distributorAddress,
        address _token,
        uint256 _amount
    ) external onlyCore {
        transferToUser(_token, payable(_distributorAddress), _amount);
    }

    function processFlashLoan(address _receiver, int256 _amount)
        external
        onlyCore
    {
        accrueInterest();

        //transfer funds to the receiver
        if (_amount < 0) {
            transferToUser(token0, payable(_receiver), uint256(-_amount));
        }

        if (_amount > 0) {
            transferToUser(token1, payable(_receiver), uint256(_amount));
        }
    }

    function _mintLPposition(
        uint256 _nftID,
        uint256 tok_amount0,
        uint256 tok_amount1
    ) internal {
        pM storage _positionMt = positionData[_nftID];

        if (tok_amount0 > 0) {
            tM storage _tm0 = token0Data;

            _positionMt.token0lendShare = _positionMt.token0lendShare.add(
                tok_amount0
            );
            _tm0.totalLendShare = _tm0.totalLendShare.add(tok_amount0);
        }

        if (tok_amount1 > 0) {
            tM storage _tm1 = token1Data;

            _positionMt.token1lendShare = _positionMt.token1lendShare.add(
                tok_amount1
            );
            _tm1.totalLendShare = _tm1.totalLendShare.add(tok_amount1);
        }
    }

    function _burnLPposition(
        uint256 _nftID,
        uint256 tok_amount0,
        uint256 tok_amount1
    ) internal {
        pM storage _positionMt = positionData[_nftID];

        if (tok_amount0 > 0) {
            tM storage _tm0 = token0Data;

            _positionMt.token0lendShare = _positionMt.token0lendShare.sub(
                tok_amount0
            );
            _tm0.totalLendShare = _tm0.totalLendShare.sub(tok_amount0);
        }

        if (tok_amount1 > 0) {
            tM storage _tm1 = token1Data;

            _positionMt.token1lendShare = _positionMt.token1lendShare.sub(
                tok_amount1
            );
            _tm1.totalLendShare = _tm1.totalLendShare.sub(tok_amount1);
        }
    }

    function _mintBposition(
        uint256 _nftID,
        uint256 tok_amount0,
        uint256 tok_amount1
    ) internal {
        pM storage _positionMt = positionData[_nftID];

        if (tok_amount0 > 0) {
            tM storage _tm0 = token0Data;

            _positionMt.token0borrowShare = _positionMt.token0borrowShare.add(
                tok_amount0
            );
            _tm0.totalBorrowShare = _tm0.totalBorrowShare.add(tok_amount0);
        }

        if (tok_amount1 > 0) {
            tM storage _tm1 = token1Data;

            _positionMt.token1borrowShare = _positionMt.token1borrowShare.add(
                tok_amount1
            );
            _tm1.totalBorrowShare = _tm1.totalBorrowShare.add(tok_amount1);
        }
    }

    function _burnBposition(
        uint256 _nftID,
        uint256 tok_amount0,
        uint256 tok_amount1
    ) internal {
        pM storage _positionMt = positionData[_nftID];

        if (tok_amount0 > 0) {
            tM storage _tm0 = token0Data;

            _positionMt.token0borrowShare = _positionMt.token0borrowShare.sub(
                tok_amount0
            );
            _tm0.totalBorrowShare = _tm0.totalBorrowShare.sub(tok_amount0);
        }

        if (tok_amount1 > 0) {
            tM storage _tm1 = token1Data;

            _positionMt.token1borrowShare = _positionMt.token1borrowShare.sub(
                tok_amount1
            );
            _tm1.totalBorrowShare = _tm1.totalBorrowShare.sub(tok_amount1);
        }
    }

    // --------

    function lend(uint256 _nftID, int256 amount)
        external
        onlyCore
        returns (uint256)
    {
        uint256 ntokens0;
        uint256 ntokens1;

        if (amount < 0) {
            tM storage _tm0 = token0Data;

            uint256 tokenBalance0 = IERC20(token0).balanceOf(address(this));
            uint256 _totTokenBalance0 = tokenBalance0.add(_tm0.totalBorrow);
            ntokens0 = calculateShare(
                _tm0.totalLendShare,
                _totTokenBalance0.sub(uint256(-amount)),
                uint256(-amount)
            );
            require(ntokens0 > 0, "Insufficient Liquidity Minted");

            emit Lend(token0, _nftID, uint256(-amount), ntokens0);
        }

        if (amount > 0) {
            tM storage _tm1 = token1Data;

            uint256 tokenBalance1 = IERC20(token1).balanceOf(address(this));
            uint256 _totTokenBalance1 = tokenBalance1.add(_tm1.totalBorrow);
            ntokens1 = calculateShare(
                _tm1.totalLendShare,
                _totTokenBalance1.sub(uint256(amount)),
                uint256(amount)
            );
            require(ntokens1 > 0, "Insufficient Liquidity Minted");

            emit Lend(token1, _nftID, uint256(amount), ntokens1);
        }

        _mintLPposition(_nftID, ntokens0, ntokens1);

        return 0;
    }

    function redeem(
        uint256 _nftID,
        int256 tok_amount,
        address _receiver
    ) external onlyCore returns (int256 _amount) {
        accrueInterest();

        pM storage _positionMt = positionData[_nftID];

        if (tok_amount < 0) {
            require(
                _positionMt.token0lendShare >= uint256(-tok_amount),
                "Balance Exceeds Requested"
            );

            tM storage _tm0 = token0Data;

            uint256 tokenBalance0 = IERC20(token0).balanceOf(address(this));
            uint256 _totTokenBalance0 = tokenBalance0.add(_tm0.totalBorrow);
            uint256 poolAmount = getShareValue(
                _totTokenBalance0,
                _tm0.totalLendShare,
                uint256(-tok_amount)
            );

            _amount = -int256(poolAmount);

            require(tokenBalance0 >= poolAmount, "Not enough Liquidity");

            _burnLPposition(_nftID, uint256(-tok_amount), 0);

            // check if _healthFactorLtv > 1
            checkHealthFactorLtv(_nftID);

            transferToUser(token0, payable(_receiver), poolAmount);

            emit Redeem(token0, _nftID, uint256(-tok_amount), poolAmount);
        }

        if (tok_amount > 0) {
            require(
                _positionMt.token1lendShare >= uint256(tok_amount),
                "Balance Exceeds Requested"
            );

            tM storage _tm1 = token1Data;

            uint256 tokenBalance1 = IERC20(token1).balanceOf(address(this));
            uint256 _totTokenBalance1 = tokenBalance1.add(_tm1.totalBorrow);
            uint256 poolAmount = getShareValue(
                _totTokenBalance1,
                _tm1.totalLendShare,
                uint256(tok_amount)
            );

            _amount = int256(poolAmount);

            require(tokenBalance1 >= poolAmount, "Not enough Liquidity");

            _burnLPposition(_nftID, 0, uint256(tok_amount));

            // check if _healthFactorLtv > 1
            checkHealthFactorLtv(_nftID);

            transferToUser(token1, payable(_receiver), poolAmount);

            emit Redeem(token1, _nftID, uint256(tok_amount), poolAmount);
        }
    }

    function redeemUnderlying(
        uint256 _nftID,
        int256 _amount,
        address _receiver
    ) external onlyCore returns (int256 rtAmount) {
        accrueInterest();

        pM storage _positionMt = positionData[_nftID];

        if (_amount < 0) {
            tM storage _tm0 = token0Data;

            uint256 tokenBalance0 = IERC20(token0).balanceOf(address(this));
            uint256 _totTokenBalance0 = tokenBalance0.add(_tm0.totalBorrow);
            uint256 tok_amount0 = getShareByValue(
                _totTokenBalance0,
                _tm0.totalLendShare,
                uint256(-_amount)
            );

            require(tok_amount0 > 0, "Insufficient Liquidity Burned");
            require(
                _positionMt.token0lendShare >= tok_amount0,
                "Balance Exceeds Requested"
            );
            require(tokenBalance0 >= uint256(-_amount), "Not enough Liquidity");

            _burnLPposition(_nftID, tok_amount0, 0);

            // check if _healthFactorLtv > 1
            checkHealthFactorLtv(_nftID);

            transferToUser(token0, payable(_receiver), uint256(-_amount));

            rtAmount = -int256(tok_amount0);

            emit Redeem(token0, _nftID, tok_amount0, uint256(-_amount));
        }

        if (_amount > 0) {
            tM storage _tm1 = token1Data;

            uint256 tokenBalance1 = IERC20(token1).balanceOf(address(this));
            uint256 _totTokenBalance1 = tokenBalance1.add(_tm1.totalBorrow);
            uint256 tok_amount1 = getShareByValue(
                _totTokenBalance1,
                _tm1.totalLendShare,
                uint256(_amount)
            );

            require(tok_amount1 > 0, "Insufficient Liquidity Burned");
            require(
                _positionMt.token1lendShare >= tok_amount1,
                "Balance Exceeds Requested"
            );
            require(tokenBalance1 >= uint256(_amount), "Not enough Liquidity");

            _burnLPposition(_nftID, 0, tok_amount1);

            // check if _healthFactorLtv > 1
            checkHealthFactorLtv(_nftID);

            transferToUser(token1, payable(_receiver), uint256(_amount));

            rtAmount = int256(tok_amount1);

            emit Redeem(token1, _nftID, tok_amount1, uint256(_amount));
        }
    }

    function borrow(
        uint256 _nftID,
        int256 amount,
        address payable _recipient
    ) external onlyCore {
        accrueInterest();

        if (amount < 0) {
            tM storage _tm0 = token0Data;

            uint256 ntokens0 = calculateShare(
                _tm0.totalBorrowShare,
                _tm0.totalBorrow,
                uint256(-amount)
            );
            require(ntokens0 > 0, "Insufficient Borrow0 Liquidity Minted");

            _mintBposition(_nftID, ntokens0, 0);

            _tm0.totalBorrow = _tm0.totalBorrow.add(uint256(-amount));

            // check if _healthFactorLtv > 1
            checkHealthFactorLtv(_nftID);

            transferToUser(token0, payable(_recipient), uint256(-amount));

            emit Borrow(
                token0,
                _nftID,
                uint256(-amount),
                _tm0.totalBorrow,
                _recipient
            );
        }

        if (amount > 0) {
            tM storage _tm1 = token1Data;

            uint256 ntokens1 = calculateShare(
                _tm1.totalBorrowShare,
                _tm1.totalBorrow,
                uint256(amount)
            );
            require(ntokens1 > 0, "Insufficient Borrow1 Liquidity Minted");

            _mintBposition(_nftID, 0, ntokens1);

            _tm1.totalBorrow = _tm1.totalBorrow.add(uint256(amount));

            // check if _healthFactorLtv > 1
            checkHealthFactorLtv(_nftID);

            transferToUser(token1, payable(_recipient), uint256(amount));

            emit Borrow(
                token1,
                _nftID,
                uint256(amount),
                _tm1.totalBorrow,
                _recipient
            );
        }
    }

    function repay(
        uint256 _nftID,
        int256 amount,
        address _payer
    ) external onlyCore returns (int256 _rAmount) {
        accrueInterest();

        pM storage _positionMt = positionData[_nftID];

        if (amount < 0) {
            tM storage _tm0 = token0Data;

            uint256 _totalBorrow = _tm0.totalBorrow;
            uint256 _totalLiability = getShareValue(
                _totalBorrow,
                _tm0.totalBorrowShare,
                _positionMt.token0borrowShare
            );

            if (uint256(-amount) > _totalLiability) {
                amount = -int256(_totalLiability);

                _burnBposition(_nftID, _positionMt.token0borrowShare, 0);

                _tm0.totalBorrow = _tm0.totalBorrow.sub(_totalLiability);
            } else {
                uint256 amountToShare = getShareByValue(
                    _totalBorrow,
                    _tm0.totalBorrowShare,
                    uint256(-amount)
                );

                _burnBposition(_nftID, amountToShare, 0);

                _tm0.totalBorrow = _tm0.totalBorrow.sub(uint256(-amount));
            }

            _rAmount = amount;

            emit RepayBorrow(
                token0,
                _nftID,
                uint256(-amount),
                _tm0.totalBorrow,
                _payer
            );
        }

        if (amount > 0) {
            tM storage _tm1 = token1Data;

            uint256 _totalBorrow = _tm1.totalBorrow;
            uint256 _totalLiability = getShareValue(
                _totalBorrow,
                _tm1.totalBorrowShare,
                _positionMt.token1borrowShare
            );

            if (uint256(amount) > _totalLiability) {
                amount = int256(_totalLiability);

                _burnBposition(_nftID, 0, _positionMt.token1borrowShare);

                _tm1.totalBorrow = _tm1.totalBorrow.sub(_totalLiability);
            } else {
                uint256 amountToShare = getShareByValue(
                    _totalBorrow,
                    _tm1.totalBorrowShare,
                    uint256(amount)
                );

                _burnBposition(_nftID, 0, amountToShare);

                _tm1.totalBorrow = _tm1.totalBorrow.sub(uint256(amount));
            }

            _rAmount = amount;

            emit RepayBorrow(
                token1,
                _nftID,
                uint256(amount),
                _tm1.totalBorrow,
                _payer
            );
        }
    }

    function liquidateInternal(
        uint256 _nftID,
        int256 amount,
        uint256 _toNftID
    ) internal returns (int256 liquidatedAmount, int256 totReceiveAmount) {
        accrueInterest();

        tM storage _tm0 = token0Data;
        tM storage _tm1 = token1Data;

        if (amount < 0) {
            (, uint256 _borrowBalance0) = userBalanceOftoken0(_nftID);
            (uint256 _lendBalance1, ) = userBalanceOftoken1(_nftID);

            uint256 _healthFactor = type(uint256).max;
            if (_borrowBalance0 > 0) {
                uint256 collateralBalance = IUnilendV2Core(core).getOraclePrice(
                    token1,
                    token0,
                    _lendBalance1
                );
                _healthFactor = (
                    collateralBalance.mul(uint256(100).sub(lb)).mul(1e18).div(
                        100
                    )
                ).div(_borrowBalance0);
            }

            if (_healthFactor < HEALTH_FACTOR_LIQUIDATION_THRESHOLD) {
                uint256 procAmountIN;
                uint256 recAmountIN;
                if (_borrowBalance0 <= uint256(-amount)) {
                    procAmountIN = _borrowBalance0;
                    recAmountIN = _lendBalance1;
                } else {
                    procAmountIN = uint256(-amount);
                    recAmountIN = (_lendBalance1.mul(procAmountIN)).div(
                        _borrowBalance0
                    );
                }

                uint256 amountToShare0 = getShareByValue(
                    _tm0.totalBorrow,
                    _tm0.totalBorrowShare,
                    procAmountIN
                );
                _burnBposition(_nftID, amountToShare0, 0);
                _tm0.totalBorrow = _tm0.totalBorrow.sub(procAmountIN); // remove borrow amount

                uint256 _totTokenBalance1 = IERC20(token1)
                    .balanceOf(address(this))
                    .add(_tm1.totalBorrow);
                uint256 amountToShare1 = getShareByValue(
                    _totTokenBalance1,
                    _tm1.totalLendShare,
                    recAmountIN
                );
                _burnLPposition(_nftID, 0, amountToShare1);

                if (_toNftID > 0) {
                    _mintLPposition(_toNftID, 0, amountToShare1);
                }

                // tot amount to be deposit from liquidator
                liquidatedAmount = -int256(procAmountIN);
                totReceiveAmount = int256(recAmountIN);

                if (liquidatedAmount < 0) {
                    emit LiquidateBorrow(
                        token0,
                        _nftID,
                        _toNftID,
                        uint256(-liquidatedAmount),
                        recAmountIN
                    );
                }
            }
        }

        if (amount > 0) {
            (uint256 _lendBalance0, ) = userBalanceOftoken0(_nftID);
            (, uint256 _borrowBalance1) = userBalanceOftoken1(_nftID);

            uint256 _healthFactor = type(uint256).max;
            if (_borrowBalance1 > 0) {
                uint256 collateralBalance = IUnilendV2Core(core).getOraclePrice(
                    token0,
                    token1,
                    _lendBalance0
                );
                _healthFactor = (
                    collateralBalance.mul(uint256(100).sub(lb)).mul(1e18).div(
                        100
                    )
                ).div(_borrowBalance1);
            }

            if (_healthFactor < HEALTH_FACTOR_LIQUIDATION_THRESHOLD) {
                uint256 procAmountIN;
                uint256 recAmountIN;
                if (_borrowBalance1 <= uint256(amount)) {
                    procAmountIN = _borrowBalance1;
                    recAmountIN = _lendBalance0;
                } else {
                    procAmountIN = uint256(amount);
                    recAmountIN = (_lendBalance0.mul(procAmountIN)).div(
                        _borrowBalance1
                    );
                }

                uint256 amountToShare1 = getShareByValue(
                    _tm1.totalBorrow,
                    _tm1.totalBorrowShare,
                    procAmountIN
                );
                _burnBposition(_nftID, 0, amountToShare1);
                _tm1.totalBorrow = _tm1.totalBorrow.sub(procAmountIN); // remove borrow amount

                uint256 _totTokenBalance0 = IERC20(token0)
                    .balanceOf(address(this))
                    .add(_tm0.totalBorrow);
                uint256 amountToShare0 = getShareByValue(
                    _totTokenBalance0,
                    _tm0.totalLendShare,
                    recAmountIN
                );
                _burnLPposition(_nftID, amountToShare0, 0);

                if (_toNftID > 0) {
                    _mintLPposition(_toNftID, amountToShare0, 0);
                }

                // tot liquidated amount to be deposit from liquidator
                liquidatedAmount = int256(procAmountIN);
                totReceiveAmount = -int256(recAmountIN);

                if (liquidatedAmount > 0) {
                    emit LiquidateBorrow(
                        token1,
                        _nftID,
                        _toNftID,
                        uint256(liquidatedAmount),
                        recAmountIN
                    );
                }
            }
        }
    }

    function liquidate(
        uint256 _nftID,
        int256 amount,
        address _receiver,
        uint256 _toNftID
    ) external onlyCore returns (int256 liquidatedAmount) {
        accrueInterest();

        int256 recAmountIN;
        (liquidatedAmount, recAmountIN) = liquidateInternal(
            _nftID,
            amount,
            _toNftID
        );

        if (_toNftID == 0) {
            if (recAmountIN < 0) {
                transferToUser(
                    token0,
                    payable(_receiver),
                    uint256(-recAmountIN)
                );
            }

            if (recAmountIN > 0) {
                transferToUser(
                    token1,
                    payable(_receiver),
                    uint256(recAmountIN)
                );
            }
        }
    }

    function liquidateMulti(
        uint256[] calldata _nftIDs,
        int256[] calldata amounts,
        address _receiver,
        uint256 _toNftID
    ) external onlyCore returns (int256 liquidatedAmountTotal) {
        accrueInterest();

        int256 liquidatedAmount;
        int256 recAmountIN;
        int256 recAmountINtotal;

        for (uint256 i = 0; i < _nftIDs.length; i++) {
            (liquidatedAmount, recAmountIN) = liquidateInternal(
                _nftIDs[i],
                amounts[i],
                _toNftID
            );

            liquidatedAmountTotal = liquidatedAmountTotal + liquidatedAmount;
            recAmountINtotal = recAmountINtotal + recAmountIN;
        }

        if (_toNftID == 0) {
            if (recAmountINtotal < 0) {
                transferToUser(
                    token0,
                    payable(_receiver),
                    uint256(-recAmountINtotal)
                );
            }

            if (recAmountINtotal > 0) {
                transferToUser(
                    token1,
                    payable(_receiver),
                    uint256(recAmountINtotal)
                );
            }
        }
    }
}
