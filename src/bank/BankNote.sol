// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, IERC165, IERC721Receiver} from "../interfaces/IERC20.sol";
import {IFuguiBankView} from "../interfaces/IFuguiBankView.sol";
import {Roles} from "../lib/Roles.sol";
import {Base64} from "../lib/Base64.sol";
import {StringsLib} from "../lib/StringsLib.sol";

/// @title BankNote — 银票
/// @notice The position-receipt NFT of FuguiBank. tokenId == positionId.
///         Metadata (a pixel-art banknote with a red 富 seal) is generated on-chain.
///         Closing a position may burn the note or keep it as a redeemed souvenir.
contract BankNote is Roles, IERC165 {
    using StringsLib for uint256;

    string public constant name = "Fugui Bank Note";
    string public constant symbol = "YINPIAO";
    bytes32 public constant ROLE_MINTER = keccak256("MINTER");

    /// @notice The bank this note renders positions for (set once, then frozen).
    IFuguiBankView public bank;
    bool public bankFrozen;

    uint256 public minted;
    uint256 public burned;

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping(uint256 => uint64) private _mintedAt;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    error NonexistentToken(uint256 tokenId);
    error TransferFromIncorrectOwner();
    error TransferToNonERC721Receiver();
    error NotAuthorized();
    error BankAlreadyFrozen();
    error ZeroAddress();

    // ------------------------------------------------------------------ wiring

    function setBank(address bank_) external onlyAdmin {
        if (bankFrozen) revert BankAlreadyFrozen();
        if (bank_ == address(0)) revert ZeroAddress();
        bank = IFuguiBankView(bank_);
    }

    function freezeBank() external onlyAdmin {
        bankFrozen = true;
    }

    // ------------------------------------------------------------------ minting

    function mint(address to, uint256 tokenId) external onlyRole(ROLE_MINTER) {
        _mint(to, tokenId);
    }

    function burn(uint256 tokenId) external onlyRole(ROLE_MINTER) {
        _burn(tokenId);
    }

    // ------------------------------------------------------------- ERC-721 core

    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert ZeroAddress();
        return _balances[owner];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address owner = _owners[tokenId];
        if (owner == address(0)) revert NonexistentToken(tokenId);
        return owner;
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        if (_owners[tokenId] == address(0)) revert NonexistentToken(tokenId);
        return _tokenApprovals[tokenId];
    }

    function isApprovedForAll(address owner, address operator) public view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function approve(address to, uint256 tokenId) external {
        address owner = ownerOf(tokenId);
        if (msg.sender != owner && !isApprovedForAll(owner, msg.sender)) revert NotAuthorized();
        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        if (ownerOf(tokenId) != from) revert TransferFromIncorrectOwner();
        if (msg.sender != from && _tokenApprovals[tokenId] != msg.sender && !isApprovedForAll(from, msg.sender)) {
            revert NotAuthorized();
        }
        if (to == address(0)) revert ZeroAddress();
        delete _tokenApprovals[tokenId];
        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        _transferAndCheck(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external {
        _transferAndCheck(from, to, tokenId, data);
    }

    function _transferAndCheck(address from, address to, uint256 tokenId, bytes memory data) internal {
        transferFrom(from, to, tokenId);
        _checkOnERC721Received(from, to, tokenId, data);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC-165
            || interfaceId == 0x80ac58cd // ERC-721
            || interfaceId == 0x5b5e139f; // ERC-721 metadata
    }

    // ------------------------------------------------------------------ metadata

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_owners[tokenId] == address(0)) revert NonexistentToken(tokenId);
        string memory json = unicode'{"name":"银票 BankNote #';
        json = string.concat(json, tokenId.toString());
        json = string.concat(
            json,
            unicode'","description":"富贵钱庄 Fugui Bank position receipt. 富贵险中求，赚了买美股. Trade memes, bank stocks.",'
        );
        json = string.concat(json, '"external_url":"https://fuguifinance.fun","image":"data:image/svg+xml;base64,');
        json = string.concat(json, Base64.encode(bytes(_svg(tokenId))));
        json = string.concat(json, '","attributes":');
        json = string.concat(json, _attributes(tokenId));
        json = string.concat(json, "}");
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function contractURI() external pure returns (string memory) {
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    unicode'{"name":"Fugui Bank Note 银票","description":"Position receipts of FuguiBank on Robinhood Chain.","external_link":"https://fuguifinance.fun"}'
                )
            )
        );
    }

    // ------------------------------------------------------------------ internals

    function _mint(address to, uint256 tokenId) internal {
        if (to == address(0)) revert ZeroAddress();
        if (_owners[tokenId] != address(0)) revert NonexistentToken(tokenId);
        _owners[tokenId] = to;
        _balances[to] += 1;
        _mintedAt[tokenId] = uint64(block.timestamp);
        minted += 1;
        emit Transfer(address(0), to, tokenId);
    }

    function _burn(uint256 tokenId) internal {
        address owner = ownerOf(tokenId);
        delete _tokenApprovals[tokenId];
        delete _owners[tokenId];
        delete _mintedAt[tokenId];
        _balances[owner] -= 1;
        burned += 1;
        emit Transfer(owner, address(0), tokenId);
    }

    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory data) private {
        if (to.code.length > 0) {
            try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 retval) {
                if (retval != IERC721Receiver.onERC721Received.selector) revert TransferToNonERC721Receiver();
            } catch {
                revert TransferToNonERC721Receiver();
            }
        }
    }

    function _position(uint256 tokenId) private view returns (IFuguiBankView.Position memory p, bool live) {
        if (address(bank) != address(0)) {
            try bank.getPosition(tokenId) returns (IFuguiBankView.Position memory pos) {
                return (pos, true);
            } catch {}
        }
        return (p, false);
    }

    function _symbolOf(address token) private view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory s) {
            return s;
        } catch {
            return "?";
        }
    }

    // ---------------------------------------------------------------- SVG artist
    // Sections are kept tiny on purpose: big chained string.concat calls
    // blow the EVM stack, so the note is assembled piece by piece.

    /// @dev A 512x288 pixel banknote: cream paper, gold frames, red 富 medallion, seal.
    function _svg(uint256 tokenId) private view returns (string memory) {
        (IFuguiBankView.Position memory p, bool live) = _position(tokenId);
        string memory memeSym = live ? _symbolOf(p.meme) : "FUGUI";
        string memory stockSym = live ? _symbolOf(p.stock) : "STOCK";

        string memory s =
            '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="288" viewBox="0 0 512 288" shape-rendering="crispEdges">';
        s = string.concat(s, _paper());
        s = string.concat(s, _medallion());
        s = string.concat(s, _faceTexts(p, live, memeSym, stockSym));
        s = string.concat(s, _serial(tokenId));
        s = string.concat(s, _seal());
        return string.concat(s, "</svg>");
    }

    function _paper() private pure returns (string memory) {
        string memory s = _rect(0, 0, 512, 288, "#efe6cf");
        for (uint256 x = 32; x < 512; x += 32) {
            s = string.concat(s, _rect(x, 0, 16, 288, "#e9dfc4"));
        }
        s = string.concat(
            s,
            _rect(0, 0, 512, 8, "#7a5a16"),
            _rect(0, 280, 512, 8, "#7a5a16"),
            _rect(0, 0, 8, 288, "#7a5a16"),
            _rect(504, 0, 8, 288, "#7a5a16")
        );
        return string.concat(
            s,
            _rect(16, 16, 480, 4, "#d4af37"),
            _rect(16, 268, 480, 4, "#d4af37"),
            _rect(16, 16, 4, 256, "#d4af37"),
            _rect(492, 16, 4, 256, "#d4af37")
        );
    }

    function _medallion() private pure returns (string memory) {
        string memory s = _rect(36, 66, 152, 152, "#7f1d16");
        s = string.concat(s, _rect(42, 72, 140, 140, "#a02c21"));
        return string.concat(s, _fu(56, 82, 9, "#f6d34f"));
    }

    function _faceTexts(
        IFuguiBankView.Position memory p,
        bool live,
        string memory memeSym,
        string memory stockSym
    ) private pure returns (string memory) {
        string memory faceValue = live ? StringsLib.formatFixed(p.srcRemaining, 2) : "0.00";
        string memory accruedValue = live ? StringsLib.formatFixed(p.dstAccrued, 4) : "0.0000";
        string memory modeCn = !live
            ? unicode"已兑付"
            : (p.mode == 0 ? unicode"落袋为安" : unicode"富贵险中求");
        string memory modeEn = !live ? "REDEEMED" : (p.mode == 0 ? "LUCKY POCKET" : "BOLD SEEKER");

        string memory s =
            unicode'<text x="210" y="66" fill="#5c4713" font-family="monospace" font-weight="bold" font-size="26" letter-spacing="4">富贵钱庄</text>';
        s = string.concat(
            s,
            unicode'<text x="212" y="90" fill="#8a6d1f" font-family="monospace" font-size="13" letter-spacing="2">FUGUI BANK NOTE · ROBINHOOD CHAIN</text>'
        );
        s = string.concat(
            s,
            unicode'<text x="212" y="128" fill="#7f1d16" font-family="monospace" font-weight="bold" font-size="17" letter-spacing="1">票面 ',
            faceValue,
            " ",
            memeSym,
            "</text>"
        );
        s = string.concat(
            s,
            unicode'<text x="212" y="152" fill="#3f5d2a" font-family="monospace" font-weight="bold" font-size="17" letter-spacing="1">已攒 ',
            accruedValue,
            " ",
            stockSym,
            "</text>"
        );
        return string.concat(
            s,
            unicode'<text x="212" y="184" fill="#5c4713" font-family="monospace" font-size="15" letter-spacing="1">模式 ',
            modeCn,
            unicode" · ",
            modeEn,
            "</text>"
        );
    }

    function _serial(uint256 tokenId) private view returns (string memory) {
        string memory s =
            '<text x="212" y="212" fill="#8a6d1f" font-family="monospace" font-size="14">No. ';
        s = string.concat(s, tokenId.toString());
        s = string.concat(s, unicode" · ");
        s = string.concat(s, StringsLib.toString(_mintedAt[tokenId]));
        s = string.concat(s, "</text>");
        return string.concat(
            s,
            unicode'<text x="212" y="244" fill="#a08a4a" font-family="monospace" font-size="11" letter-spacing="1">富贵险中求 · 赚了买美股 · TRADE MEMES, BANK STOCKS</text>'
        );
    }

    function _seal() private pure returns (string memory) {
        string memory s = _rect(408, 196, 68, 68, "#a02c21");
        s = string.concat(s, _rect(414, 202, 56, 56, "#c0392b"));
        return string.concat(s, _fu(421, 206, 3, "#f6d34f"));
    }

    /// @dev The 富 glyph as a 12x13 bitmap, drawn as `cell`-sized rects at (ox, oy).
    function _fu(uint256 ox, uint256 oy, uint256 cell, string memory color)
        private
        pure
        returns (string memory)
    {
        string[13] memory rows = [
            "......X.....",
            ".....XXX....",
            "XXXXXXXXXXXX",
            ".X...X....X.",
            "..XXXXXXXXX.",
            ".XXXXXXXXXX.",
            "....X...X...",
            "...X.X.X.X..",
            "...XXXXXXX..",
            "...X.X.X.X..",
            "...XXXXXXX..",
            "...X.X.X.X..",
            "...XXXXXXX.."
        ];
        string memory out;
        for (uint256 y = 0; y < 13; y++) {
            bytes memory row = bytes(rows[y]);
            for (uint256 x = 0; x < 12; x++) {
                if (row[x] == "X") {
                    out = string.concat(out, _rect(ox + x * cell, oy + y * cell, cell, cell, color));
                }
            }
        }
        return out;
    }

    function _rect(uint256 x, uint256 y, uint256 w, uint256 h, string memory color)
        private
        pure
        returns (string memory)
    {
        string memory s = '<rect x="';
        s = string.concat(s, x.toString());
        s = string.concat(s, '" y="');
        s = string.concat(s, y.toString());
        s = string.concat(s, '" width="');
        s = string.concat(s, w.toString());
        s = string.concat(s, '" height="');
        s = string.concat(s, h.toString());
        s = string.concat(s, '" fill="');
        s = string.concat(s, color);
        return string.concat(s, '"/>');
    }

    function _attributes(uint256 tokenId) private view returns (string memory) {
        (IFuguiBankView.Position memory p, bool live) = _position(tokenId);
        if (!live) {
            return '[{"trait_type":"Status","value":"REDEEMED"}]';
        }
        string memory s = '[{"trait_type":"Mode","value":';
        s = string.concat(s, p.mode == 0 ? unicode'"落袋为安 LUCKY"' : unicode'"富贵险中求 BOLD"');
        s = string.concat(s, '},{"trait_type":"Meme","value":"');
        s = string.concat(s, _symbolOf(p.meme));
        s = string.concat(s, '"},{"trait_type":"Stock","value":"');
        s = string.concat(s, _symbolOf(p.stock));
        s = string.concat(s, '"},{"trait_type":"Step Bps","value":');
        s = string.concat(s, StringsLib.toString(uint256(p.stepBps)));
        s = string.concat(s, '},{"trait_type":"Sell Bps","value":');
        s = string.concat(s, StringsLib.toString(uint256(p.sellBps)));
        s = string.concat(s, '},{"trait_type":"Harvests","value":');
        s = string.concat(s, StringsLib.toString(uint256(p.harvestCount)));
        s = string.concat(s, '},{"trait_type":"Status","value":');
        s = string.concat(s, p.closed ? '"REDEEMED"' : '"ACTIVE"');
        return string.concat(s, "}]");
    }
}

/// @notice symbol()/name() probe for metadata rendering.
interface IERC20Metadata {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}
