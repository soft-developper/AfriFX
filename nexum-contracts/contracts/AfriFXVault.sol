// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IUSDC.sol";

/**
 * @title AfriFXVault
 * @notice Handles FX conversion + P2P marketplace with:
 *   - Market orders (live rate) and Limit orders (±5% of market)
 *   - Perpetual offers (no on-chain expiry — backend enforces timers)
 *   - Maker-set timer for taker completion window
 *
 * Arc Testnet USDC: 0x3600000000000000000000000000000000000000
 * Chain ID: 5042002
 */
contract AfriFXVault is Ownable, ReentrancyGuard, Pausable {

    IUSDC public immutable usdc;

    uint256 public spreadBps  = 50;
    uint256 public p2pFeeBps  = 30;
    uint256 public constant MAX_SPREAD_BPS = 200;

    enum OfferStatus { Open, Accepted, Released, Cancelled }
    enum OrderType   { Market, Limit }

    struct P2POffer {
        bytes32     offerId;
        address     maker;
        address     taker;
        uint256     usdcAmount;
        string      localCurrency;
        uint256     localAmount;        // auto-calculated from rate
        uint256     rateOffered;        // local units per USDC * 1e6
        OrderType   orderType;          // Market or Limit
        uint256     makerTimerSeconds;  // window maker gives taker
        OfferStatus status;
        bool        makerConfirmed;     // maker received local currency
        bool        takerConfirmed;     // taker sent local currency
    }

    mapping(bytes32 => P2POffer) public offers;

    uint256 public p2pFeeBps_ = 30;

    event OfferCreated(
        bytes32 indexed offerId,
        address indexed maker,
        uint256 usdcAmount,
        string  localCurrency,
        uint256 localAmount,
        uint8   orderType,
        uint256 makerTimerSeconds
    );
    event OfferAccepted(bytes32 indexed offerId, address indexed taker);
    event TakerConfirmed(bytes32 indexed offerId);
    event MakerConfirmed(bytes32 indexed offerId);
    event OfferReleased(bytes32 indexed offerId, address indexed taker, uint256 amount);
    event OfferCancelled(bytes32 indexed offerId, string reason);
    event ConversionRequested(address indexed user, uint256 amount, string currency, uint256 ts);
    event FundsWithdrawn(address indexed to, uint256 amount);

    constructor(address _usdc) Ownable(msg.sender) {
        usdc = IUSDC(_usdc);
    }

    // ── FX Conversion ────────────────────────────────────────

    function requestConversion(
        uint256 amount,
        string calldata targetCurrency
    ) external nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be > 0");
        usdc.transferFrom(msg.sender, address(this), amount);
        emit ConversionRequested(msg.sender, amount, targetCurrency, block.timestamp);
    }

    // ── P2P Marketplace ──────────────────────────────────────

    /**
     * @notice Create a perpetual P2P offer (no on-chain expiry).
     * @param usdcAmount       USDC to lock (6 decimals)
     * @param localCurrency    ISO code e.g. "NGN"
     * @param localAmount      Local currency amount (calculated from rate off-chain)
     * @param orderType        0=Market, 1=Limit
     * @param makerTimerSeconds Window given to taker after accepting (in seconds)
     */
    function createP2POffer(
        uint256 usdcAmount,
        string  calldata localCurrency,
        uint256 localAmount,
        uint8   orderType,
        uint256 makerTimerSeconds
    ) external nonReentrant whenNotPaused returns (bytes32 offerId) {
        require(usdcAmount    > 0,  "Amount required");
        require(localAmount   > 0,  "Local amount required");
        require(makerTimerSeconds >= 5 minutes, "Min timer: 5 minutes");
        require(makerTimerSeconds <= 24 hours,  "Max timer: 24 hours");

        usdc.transferFrom(msg.sender, address(this), usdcAmount);

        offerId = keccak256(abi.encodePacked(
            msg.sender, usdcAmount, localCurrency, block.timestamp, block.prevrandao
        ));

        uint256 rate = (usdcAmount * 1e6) / localAmount;

        offers[offerId] = P2POffer({
            offerId:           offerId,
            maker:             msg.sender,
            taker:             address(0),
            usdcAmount:        usdcAmount,
            localCurrency:     localCurrency,
            localAmount:       localAmount,
            rateOffered:       rate,
            orderType:         OrderType(orderType),
            makerTimerSeconds: makerTimerSeconds,
            status:            OfferStatus.Open,
            makerConfirmed:    false,
            takerConfirmed:    false
        });

        emit OfferCreated(offerId, msg.sender, usdcAmount, localCurrency, localAmount, orderType, makerTimerSeconds);
    }

    function acceptP2POffer(bytes32 offerId) external nonReentrant {
        P2POffer storage offer = offers[offerId];
        require(offer.status   == OfferStatus.Open, "Offer not open");
        require(offer.maker    != msg.sender,        "Cannot self-trade");
        offer.taker  = msg.sender;
        offer.status = OfferStatus.Accepted;
        emit OfferAccepted(offerId, msg.sender);
    }

    // Taker confirms they SENT local currency to maker
    function takerConfirm(bytes32 offerId) external {
        P2POffer storage offer = offers[offerId];
        require(offer.status == OfferStatus.Accepted, "Offer not accepted");
        require(offer.taker  == msg.sender,           "Not the taker");
        offer.takerConfirmed = true;
        emit TakerConfirmed(offerId);
    }

    // Maker confirms they RECEIVED local currency from taker
    function makerConfirm(bytes32 offerId) external {
        P2POffer storage offer = offers[offerId];
        require(offer.status == OfferStatus.Accepted, "Offer not accepted");
        require(offer.maker  == msg.sender,           "Not the maker");
        offer.makerConfirmed = true;
        emit MakerConfirmed(offerId);
    }

    // Platform releases USDC to taker (owner only)
    function releaseP2POffer(bytes32 offerId) external onlyOwner nonReentrant {
        P2POffer storage offer = offers[offerId];
        require(offer.status == OfferStatus.Accepted, "Offer not accepted");
        require(offer.taker  != address(0),           "No taker");
        uint256 fee    = (offer.usdcAmount * p2pFeeBps) / 10_000;
        uint256 payout = offer.usdcAmount - fee;
        offer.status   = OfferStatus.Released;
        usdc.transfer(offer.taker, payout);
        emit OfferReleased(offerId, offer.taker, payout);
    }

    // Platform cancels and returns USDC to maker (owner only)
    function cancelP2POffer(bytes32 offerId, string calldata reason) external onlyOwner nonReentrant {
        P2POffer storage offer = offers[offerId];
        require(
            offer.status == OfferStatus.Open ||
            offer.status == OfferStatus.Accepted,
            "Cannot cancel"
        );
        offer.status = OfferStatus.Cancelled;
        usdc.transfer(offer.maker, offer.usdcAmount);
        emit OfferCancelled(offerId, reason);
    }

    // Maker cancels own open offer
    function makerCancelOffer(bytes32 offerId) external nonReentrant {
        P2POffer storage offer = offers[offerId];
        require(offer.status == OfferStatus.Open, "Offer not open");
        require(offer.maker  == msg.sender,       "Not the maker");
        offer.status = OfferStatus.Cancelled;
        usdc.transfer(offer.maker, offer.usdcAmount);
        emit OfferCancelled(offerId, "Maker cancelled");
    }

    function getOffer(bytes32 offerId) external view returns (P2POffer memory) {
        return offers[offerId];
    }

    function withdraw(address to, uint256 amount) external onlyOwner nonReentrant {
        usdc.transfer(to, amount);
        emit FundsWithdrawn(to, amount);
    }

    function setSpreadBps(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_SPREAD_BPS, "Too high");
        spreadBps = _bps;
    }

    function setP2PFeeBps(uint256 _bps) external onlyOwner {
        require(_bps <= 100, "Max 1%");
        p2pFeeBps = _bps;
    }

    function calcSpread(uint256 amount) public view returns (uint256) {
        return (amount * spreadBps) / 10_000;
    }

    function vaultBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function pause()   external onlyOwner { _pause();   }
    function unpause() external onlyOwner { _unpause(); }
}
