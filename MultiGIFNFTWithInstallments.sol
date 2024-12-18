// SPDX-License-Identifier: MIT
pragma solidity  ^0.8.20;
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

abstract contract ReentrancyGuard {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status;

    error ReentrancyGuardReentrantCall();

    constructor() {
        _status = NOT_ENTERED;
    }

    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        if (_status == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }

        _status = ENTERED;
    }

    function _nonReentrantAfter() private {
        _status = NOT_ENTERED;
    }
}

contract MultiGIFNFTWithInstallments is
    ERC1155,
    Ownable,
    ReentrancyGuard
{
    uint256 public nextTokenId = 1;
    struct TokenInfo {
        string gifURI;
        uint256 priceInUSD;
        uint256 downPaymentPercent;
        uint256 installmentCount;
        uint256 installmentInterval;
        uint256 earlyDiscountPercent;
        uint256 gracePeriod;
    }
    struct PaymentInfo {
        uint256 totalPaid;
        uint256 nextDueDate;
        uint256 remainingInstallments;
        uint256 lateFeePaid;
        bool active;
        bool defaulted;
    }
    mapping(uint256 => TokenInfo) public tokenInfo;
    mapping(address => mapping(uint256 => PaymentInfo)) public payments;
    AggregatorV3Interface internal immutable priceFeed;
    uint256 public manualFallbackPrice = 2000 * 1e8;
    uint256 public lateFeePercent = 5;
    event InstallmentPlanStarted(
        address indexed buyer,
        uint256 indexed tokenId,
        uint256 downPayment
    );
    event InstallmentPaymentMade(
        address indexed buyer,
        uint256 indexed tokenId,
        uint256 amountPaid,
        uint256 remainingInstallments
    );
    event EarlySettlementCompleted(
        address indexed buyer,
        uint256 indexed tokenId
    );
    event DefaultMarked(address indexed buyer, uint256 indexed tokenId);
    event NFTReclaimed(address indexed buyer, uint256 indexed tokenId);
    event FallbackPriceUsed(uint256 fallbackPrice);

    constructor(address _priceFeed, address _owner) ERC1155("") Ownable(_owner) {
         priceFeed = AggregatorV3Interface(_priceFeed);
    }

    // Function to add new tokens
    function addToken(
        string calldata gifURI,
        uint256 priceInUSD,
        uint256 downPaymentPercent,
        uint256 installmentCount,
        uint256 installmentInterval,
        uint256 earlyDiscountPercent,
        uint256 gracePeriod
    ) external onlyOwner {
        require(downPaymentPercent <= 100, "Invalid down payment percentage");
        require(installmentCount > 0, "Installments must be greater than zero");
        require(
            earlyDiscountPercent <= 100,
            "Invalid early discount percentage"
        );
        tokenInfo[nextTokenId++] = TokenInfo({
            gifURI: gifURI,
            priceInUSD: priceInUSD,
            downPaymentPercent: downPaymentPercent,
            installmentCount: installmentCount,
            installmentInterval: installmentInterval,
            earlyDiscountPercent: earlyDiscountPercent,
            gracePeriod: gracePeriod
        });
    }

    // Start an installment plan
    function startInstallmentPlan(uint256 tokenId)
        external
        payable
        nonReentrant
    {
        TokenInfo memory token = tokenInfo[tokenId];
        require(bytes(token.gifURI).length > 0, "Token does not exist");
        uint256 totalPriceInWei = getPriceInWei(token.priceInUSD);
        uint256 downPaymentRequired = (totalPriceInWei *
            token.downPaymentPercent) / 100;
        require(msg.value >= downPaymentRequired, "Insufficient down payment");

        PaymentInfo storage payment = payments[msg.sender][tokenId];
        require(!payment.active, "Installment plan already active");
        payment.totalPaid = msg.value;
        payment.nextDueDate = block.timestamp + token.installmentInterval;
        payment.remainingInstallments = token.installmentCount - 1;
        payment.active = true;
        payment.defaulted = false;
        emit InstallmentPlanStarted(msg.sender, tokenId, msg.value);
    }

    // Make an installment payment
    function makeInstallmentPayment(uint256 tokenId)
        external
        payable
        nonReentrant
    {
        PaymentInfo storage payment = payments[msg.sender][tokenId];
        require(payment.active, "Installment plan not active");
        require(!payment.defaulted, "Installment plan defaulted");
        TokenInfo memory token = tokenInfo[tokenId];
        uint256 totalPriceInWei = getPriceInWei(token.priceInUSD);
        uint256 installmentAmount = totalPriceInWei / token.installmentCount;
        uint256 lateFee = 0;
        if (block.timestamp > payment.nextDueDate + token.gracePeriod) {
            lateFee = (installmentAmount * lateFeePercent) / 100;
            require(
                msg.value >= installmentAmount + lateFee,
                "Payment insufficient to cover late fees"
            );
            payment.lateFeePaid += lateFee;
        } else {
            require(
                msg.value >= installmentAmount,
                "Payment insufficient for installment"
            );
        }
        payment.totalPaid += msg.value;
        payment.remainingInstallments--;
        payment.nextDueDate = block.timestamp + token.installmentInterval;
        emit InstallmentPaymentMade(
            msg.sender,
            tokenId,
            msg.value,
            payment.remainingInstallments
        );
        if (payment.remainingInstallments == 0) {
            payment.active = false;
            _safeTransferFrom(owner(), msg.sender, tokenId, 1, "");
        }
    }

    // Settle early
    function settleEarly(uint256 tokenId) external payable nonReentrant {
        PaymentInfo storage payment = payments[msg.sender][tokenId];
        require(payment.active, "Installment plan not active");
        require(!payment.defaulted, "Installment plan defaulted");
        TokenInfo memory token = tokenInfo[tokenId];
        uint256 totalPriceInWei = getPriceInWei(token.priceInUSD);
        uint256 discountedPrice = (totalPriceInWei *
            (100 - token.earlyDiscountPercent)) / 100;
        uint256 totalRequiredForEarlySettlement = discountedPrice +
            payment.lateFeePaid;
        require(
            payment.totalPaid + msg.value >= totalRequiredForEarlySettlement,
            "Insufficient payment for early settlement"
        );
        payment.active = false;
        emit EarlySettlementCompleted(msg.sender, tokenId);
        _safeTransferFrom(owner(), msg.sender, tokenId, 1, "");
    }

    // Mark default
    function markDefault(uint256 tokenId, address buyer) external onlyOwner {
        PaymentInfo storage payment = payments[buyer][tokenId];
        require(payment.active, "Plan not active");
        require(
            block.timestamp >
                payment.nextDueDate + tokenInfo[tokenId].gracePeriod,
            "Within grace period"
        );
        require(payment.remainingInstallments > 0, "Plan already completed");
        payment.defaulted = true;
        emit DefaultMarked(buyer, tokenId);
    }

    // Reclaim NFT
    function reclaimNFT(uint256 tokenId, address buyer)
        external
        onlyOwner
        nonReentrant
    {
        PaymentInfo storage payment = payments[buyer][tokenId];
        require(payment.defaulted, "Plan not defaulted");
        uint256 buyerBalance = balanceOf(buyer, tokenId);
        require(buyerBalance > 0, "Buyer does not own the NFT");
        payment.active = false;
        emit NFTReclaimed(buyer, tokenId);
        _safeTransferFrom(buyer, owner(), tokenId, buyerBalance, "");
    }

    // Calculate price in Wei from USD
    function getPriceInWei(uint256 priceInUSD) public returns (uint256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        if (price > 0) {
            return (priceInUSD * 1e18) / uint256(price);
        } else {
            emit FallbackPriceUsed(manualFallbackPrice);
            return (priceInUSD * 1e18) / manualFallbackPrice;
        }
    }
}