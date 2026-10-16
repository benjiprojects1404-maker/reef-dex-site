// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ReefZap} from "./ReefZap.sol";

/// @title ReefCards: COOKED x NOCAP stat-battle cards
/// @notice 150 cards (75 COOKED, 75 NOCAP). Each mint costs a fixed BDAG price and the whole
///         payment is added to that brand's Reef pool; the LP tokens go to the dead address.
///         There is no withdraw function: nobody, including the owner, can take the BDAG.
/// @dev Rarity is fixed by a pre-published provenance hash of the shuffled card order and a
///      starting offset drawn from a future block hash after sell-out (or after `revealAfter`).
contract ReefCards is ERC721, ERC2981, Ownable, ReentrancyGuard, ReefZap {
    using Strings for uint256;

    uint256 public constant PER_BRAND = 75;
    uint256 public constant MAX_PER_WALLET = 2;
    uint8 public constant COOKED = 0;
    uint8 public constant NOCAP = 1;

    uint256 public immutable price; // BDAG per mint (18 decimals)
    address public immutable cookedToken;
    address public immutable nocapToken;
    bytes32 public immutable provenance; // keccak256 of the shuffled card list, published before the sale
    uint256 public immutable revealAfter; // reveal is allowed after this time even if not sold out

    bool public saleOpen;
    bool public metadataFrozen;
    string private _base;

    uint256[2] public minted;
    mapping(address => uint256) public mintedBy;

    uint256 public startingIndexBlock;
    uint256 public startingIndex;
    bool public revealed;

    event CardMinted(address indexed to, uint256 indexed tokenId, uint8 brand, uint256 bdagIn, uint256 liquidityBurned);
    event SaleOpen(bool open);
    event StartingIndexBlockSet(uint256 blockNumber);
    event Revealed(uint256 startingIndex);
    event BaseURI(string uri);
    event MetadataFrozen();

    struct Config {
        address router;
        address factory;
        address wbdag;
        address cooked;
        address nocap;
        uint256 price;
        bytes32 provenance;
        uint256 revealAfter;
        address royaltyReceiver;
        string baseURI;
    }

    constructor(Config memory c)
        ERC721("COOKED x NOCAP Cards", "CARDS")
        Ownable(msg.sender)
        ReefZap(c.router, c.factory, c.wbdag)
    {
        require(c.cooked != address(0) && c.nocap != address(0) && c.cooked != c.nocap, "bad tokens");
        require(c.price > 0, "bad price");
        require(c.royaltyReceiver != address(0), "bad royalty receiver");
        cookedToken = c.cooked;
        nocapToken = c.nocap;
        price = c.price;
        provenance = c.provenance;
        revealAfter = c.revealAfter;
        _base = c.baseURI;
        _setDefaultRoyalty(c.royaltyReceiver, 500); // 5%
        _approveRouter(c.cooked);
        _approveRouter(c.nocap);
    }

    // ------------------------------------------------------------------ mint

    /// @param brand 0 = COOKED, 1 = NOCAP
    /// @param minTokensOut slippage floor for the swap leg (the mint page quotes it from the pool)
    function mint(uint8 brand, uint256 minTokensOut, uint256 deadline) external payable nonReentrant {
        require(saleOpen, "sale closed");
        require(brand <= NOCAP, "bad brand");
        require(msg.value == price, "wrong price");
        require(mintedBy[msg.sender] < MAX_PER_WALLET, "wallet limit");
        uint256 n = minted[brand];
        require(n < PER_BRAND, "sold out");

        minted[brand] = n + 1;
        mintedBy[msg.sender] += 1;
        uint256 tokenId = uint256(brand) * PER_BRAND + n + 1; // COOKED 1-75, NOCAP 76-150

        uint256 liquidity = _zap(brand == COOKED ? cookedToken : nocapToken, msg.value, minTokensOut, deadline);

        if (startingIndexBlock == 0 && minted[COOKED] == PER_BRAND && minted[NOCAP] == PER_BRAND) {
            startingIndexBlock = block.number;
            emit StartingIndexBlockSet(block.number);
        }
        _safeMint(msg.sender, tokenId);
        emit CardMinted(msg.sender, tokenId, brand, msg.value, liquidity);
    }

    function totalMinted() external view returns (uint256) {
        return minted[COOKED] + minted[NOCAP];
    }

    // ---------------------------------------------------------------- reveal

    /// @notice Anyone can fix the reveal block once both brands sell out or `revealAfter` passes.
    function setStartingIndexBlock() external {
        require(startingIndexBlock == 0, "already set");
        require(block.timestamp >= revealAfter, "too early");
        startingIndexBlock = block.number;
        emit StartingIndexBlockSet(block.number);
    }

    /// @notice Anyone can reveal from a block after the reveal block.
    function reveal() external {
        require(!revealed, "already revealed");
        require(startingIndexBlock != 0 && block.number > startingIndexBlock, "not ready");
        bytes32 h = blockhash(startingIndexBlock);
        if (h == bytes32(0)) h = blockhash(block.number - 1); // more than 256 blocks later
        startingIndex = uint256(h) % PER_BRAND;
        revealed = true;
        emit Revealed(startingIndex);
    }

    /// @notice Card number (1-150, the position in the provenance list) behind a token.
    function cardOf(uint256 tokenId) public view returns (uint256) {
        _requireOwned(tokenId);
        require(revealed, "not revealed");
        uint256 brandOffset = tokenId > PER_BRAND ? PER_BRAND : 0;
        uint256 n = tokenId - 1 - brandOffset;
        return brandOffset + ((n + startingIndex) % PER_BRAND) + 1;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (!revealed) {
            return string.concat(_base, tokenId > PER_BRAND ? "nocap-hidden.json" : "cooked-hidden.json");
        }
        return string.concat(_base, cardOf(tokenId).toString(), ".json");
    }

    // ----------------------------------------------------------------- admin

    function setSaleOpen(bool open) external onlyOwner {
        saleOpen = open;
        emit SaleOpen(open);
    }

    function setBaseURI(string calldata uri) external onlyOwner {
        require(!metadataFrozen, "frozen");
        _base = uri;
        emit BaseURI(uri);
    }

    function freezeMetadata() external onlyOwner {
        require(revealed, "reveal first");
        metadataFrozen = true;
        emit MetadataFrozen();
    }

    function supportsInterface(bytes4 id) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(id);
    }

    /// @dev Only the router's refunds of unused BDAG should land here. Such dust can only ever be
    ///      added to a pool via `sweepDust`; there is no way to send BDAG anywhere else.
    receive() external payable {}

    /// @notice Anyone can add stray BDAG dust in this contract to the COOKED pool.
    function sweepDust(uint256 minTokensOut, uint256 deadline) external nonReentrant {
        uint256 bal = address(this).balance;
        require(bal > 0, "no dust");
        _zap(cookedToken, bal, minTokensOut, deadline);
    }
}
