// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Burnable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract TestToken is ERC20Burnable {
    constructor() ERC20("Test", "TST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FeeToken is TestToken {
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 10;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

contract SelectiveFalseToken is TestToken {
    address public blocked;

    function setBlocked(address account) external {
        blocked = account;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (to == blocked) return false;
        return super.transferFrom(from, to, amount);
    }
}

contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract TestNFT is ERC721Burnable {
    constructor() ERC721("Test NFT", "TNFT") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

contract NonBurnableToken is ERC20 {
    constructor() ERC20("No burn", "NBRN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract NonBurnableNFT is ERC721 {
    constructor() ERC721("No burn NFT", "NBNFT") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

contract FakeBurnToken is TestToken {
    function burn(uint256) public override {}
}

contract FakeBurnNFT is TestNFT {
    function burn(uint256) public override {}
}

contract MaskedOwnerFakeBurnNFT is TestNFT {
    bool private mask;

    function burn(uint256) public override {
        mask = true;
    }

    function ownerOf(uint256 id) public view override returns (address) {
        require(!mask, "masked query");
        return super.ownerOf(id);
    }
}

contract ReentrantToken is TestToken {
    address public target;
    bytes public payload;
    bool public guardObserved;

    function configure(address router, bytes calldata data) external {
        target = router;
        payload = data;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        (bool ok, bytes memory result) = target.call(payload);
        guardObserved =
            !ok && result.length >= 4 && bytes4(result) == bytes4(keccak256("ReentrancyGuardReentrantCall()"));
        require(guardObserved, "shared guard missing");
        return super.transferFrom(from, to, amount);
    }
}

contract ReentrantNFTReceiver is IERC721Receiver {
    address public target;
    bytes public payload;
    bool public guardObserved;

    function configure(address router, bytes calldata data) external {
        target = router;
        payload = data;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        (bool ok, bytes memory result) = target.call(payload);
        guardObserved =
            !ok && result.length >= 4 && bytes4(result) == bytes4(keccak256("ReentrancyGuardReentrantCall()"));
        require(guardObserved, "shared guard missing");
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract NonReceiver {}
