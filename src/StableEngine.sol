// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {OAppOptionsType3} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import {IStableCoin} from "./interfaces/IStableCoin.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/interfaces/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface IChainlinkDataFeed {
    function latestAnswer() external returns (int256);
}

contract StableEngine is OApp, OAppOptionsType3, IERC721Receiver {
    // ====================
    // === STORAGE VARS ===
    // ====================

    string public data;
    uint256 public number;
    address public user;

    uint256 public liqudationAmount;

    // _dstEid of chain this contract is on
    // to detect 'mintToSender' for *THIS* chain and not a remote chain
    uint32 public lzDstEidOfThisChain;

    // Stablecoin vars
    address public stableCoinContract;

    // NFT vars
    address[] public whitelistedNFTs;
    address[] public nftOracles;
    mapping(address nftAddress => mapping(uint256 tokenId => address supplier)) public
        nftCollectionTokenIdToSupplierAddress;
    mapping(address user => mapping(address nftAddress => uint256 count)) public userAddressToNftCollectionSuppliedCount;
    mapping(address supplier => uint256 nftSupplied) public numberOfNftsUserHasSupplied;
    mapping(address user => uint256 stablecoinsMinted) public userAddressToNumberOfStablecoinsMinted;

    mapping(address user => mapping(address nftCollection => uint256[] tokenIds)) public
        userAddressToNftCollectionTokenIds;

    mapping(address liquidatableUser => uint256 liquidationAmount) public liquidatableUsersToLiquidationAmounts;

    // CR and Health Factor vars
    uint256 public COLLATERALISATION_RATIO = 5e17; // aka 50%
    uint256 public MIN_HEALTH_FACTOR = 1e18; // aka 1.0

    uint16 public constant SEND = 1;
    uint16 public constant SEND_ABA = 2;

    enum ChainSelection {
        Base,
        Optimism,
        Arbitrum,
        Scroll,
        Linea
    }

    // ==============
    // === ERRORS ===
    // ==============

    error UserDidNotSupplyTheNFTOriginally(uint256 tokenId);
    error UserHasOutstandingDebt(uint256 outstandingDebt);
    error mintFailed();
    error ChainNotSpecified();
    error NoNftsCurrentlySupplied();
    error Error__NftIsNotAcceptedCollateral();
    error InvalidMsgType();
    error MaxCollateralisationRatioReached();

    // ==============
    // === EVENTS ===
    // ==============

    event NftSuppliedToContract(address indexed _nftAddress, uint256 indexed _tokenId);
    event NftWithdrawnByUser(address indexed user, uint256 indexed tokenId);
    event MintOnChainFunctionSuccessful();

    event MintContractCalled();

    // test events - remove
    event OptimismSelected();
    event ArbitrumSelected();
    event Received();
    // event MessageSent(string _message, uint32 _dstEid);
    event AttemptedLzSendFromCheckBorrowerStatus();
    event LiquidationStatusReceivedOnSourceChain(uint256 amount, uint8 choice);

    event MessageSent(uint32 dstEid);
    event ReturnMessageSent(uint32 dstEid);
    event MessageReceived(string message, uint32 senderEid, bytes32 sender);

    constructor(address _endpoint, address _owner) OApp(_endpoint, _owner) Ownable(_owner) {}

    // ================================
    // === SUPPLY NFT AS COLLATERAL ===
    // ================================

    // @todo MAKE NON-REENTRANT
    function supply(address _nftAddress, uint256 _tokenId) public {
        // *** EOA has to call approve() on the NFT contract to allow this contract to take control of the NFT id number ***

        // check if nft is acceptable collateral
        for (uint256 i = 0; i < whitelistedNFTs.length; i++) {
            if (whitelistedNFTs[i] == _nftAddress) {
                break;
            } else {
                revert Error__NftIsNotAcceptedCollateral();
            }
        }

        // accept NFT into the contract
        IERC721(_nftAddress).safeTransferFrom(msg.sender, address(this), _tokenId);

        // update mapping to account for who can withdraw a specific NFT tokenId
        nftCollectionTokenIdToSupplierAddress[_nftAddress][_tokenId] = msg.sender;

        // we always liquidate at floor price, so just need to count how many of each collection they've supplied
        userAddressToNftCollectionSuppliedCount[msg.sender][_nftAddress]++;

        // for our frontend to render the user's specific NFTs
        userAddressToNftCollectionTokenIds[msg.sender][_nftAddress].push(_tokenId);

        numberOfNftsUserHasSupplied[msg.sender]++;

        emit NftSuppliedToContract(_nftAddress, _tokenId);
    }

    // ====================
    // === WITHDRAW NFT ===
    // ====================

    function withdraw(address _nftAddress, uint256 _tokenId) public {
        // check that the requested tokenId is the one the user supplied initially
        if (msg.sender == nftCollectionTokenIdToSupplierAddress[_nftAddress][_tokenId]) {
            // check if health factor will be broken if user withdraws an NFT
            uint256 healthFactorAfterWithdrawal = _simulateBorrowerHealthFactorAfterWithdrawal(msg.sender);
            if (healthFactorAfterWithdrawal > MIN_HEALTH_FACTOR) {
                // if both are ok, transfer the NFT to them
                IERC721(_nftAddress).transferFrom(address(this), msg.sender, _tokenId);

                nftCollectionTokenIdToSupplierAddress[_nftAddress][_tokenId] = address(0x0); // zero out address that supplied this NFT token id
                userAddressToNftCollectionSuppliedCount[msg.sender][_nftAddress]--;
                numberOfNftsUserHasSupplied[msg.sender]--;

                emit NftWithdrawnByUser(msg.sender, _tokenId);
            } else {
                revert UserHasOutstandingDebt(userAddressToNumberOfStablecoinsMinted[msg.sender]);
            }
        } else {
            revert UserDidNotSupplyTheNFTOriginally(_tokenId);
        }
    }

    function repay(uint32 _dstEid, uint256 _amount, address _recipient, uint8 _choice, bytes calldata _options)
        public
        payable
    {
        if (_dstEid == lzDstEidOfThisChain) {
            // take in the StableCoins
            IStableCoin(stableCoinContract).transferFrom(msg.sender, address(this), _amount); // approval required first on frontend
            userAddressToNumberOfStablecoinsMinted[_recipient] -= _amount; // update balance
        } else {
            // take in the StableCoins
            IStableCoin(stableCoinContract).transferFrom(msg.sender, address(this), _amount); // approval required first on frontend

            // _lzSend to dstEid to repay debt
            bytes memory _payload = abi.encode(_amount, _recipient, 4); // choice 4 to repay debt on Base
            _lzSend(_dstEid, _payload, _options, MessagingFee(msg.value, 0), payable(msg.sender));
        }
    }

    // ===============================
    // === LAYERZERO FUNCTIONALITY ===
    // ===============================

    // ===============
    // === LZ SEND ===
    // ===============

    function sendToMinter(uint32 _dstEid, uint256 _amount, address _recipient, uint8 _choice, bytes calldata _options)
        external
        payable
        returns (MessagingReceipt memory receipt)
    {
        if (_dstEid == lzDstEidOfThisChain) {
            IStableCoin(stableCoinContract).mint(_recipient, _amount);
        } else {
            // has user supplied an nft as collateral
            if (numberOfNftsUserHasSupplied[msg.sender] == 0) {
                revert NoNftsCurrentlySupplied();
            }

            // calculate max amount user can mint
            uint256 maxStablecoinCanBeMinted = _calculateMaxMintableByUser(msg.sender);

            // check if acceptable amount
            if (_amount <= maxStablecoinCanBeMinted) {
                bytes memory _payload = abi.encode(_amount, _recipient, _choice);
                receipt = _lzSend(_dstEid, _payload, _options, MessagingFee(msg.value, 0), payable(msg.sender));
                // update user balance
                userAddressToNumberOfStablecoinsMinted[msg.sender] += _amount;
            } else {
                revert MaxCollateralisationRatioReached();
            }
        }
    }

    // ================
    // === LZ QUOTE ===
    // ================

    function quote(uint32 _dstEid, string memory _message, bytes memory _options, bool _payInLzToken)
        public
        view
        returns (MessagingFee memory fee)
    {
        bytes memory payload = abi.encode(_message);
        fee = _quote(_dstEid, payload, _options, _payInLzToken);
    }

    // ==================
    // === LZ RECEIVE ===
    // ==================

    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata payload,
        address, /*_executor*/
        bytes calldata /*_extraData*/
    ) internal override {
        (uint256 amount, address recipient, uint8 choice) = abi.decode(payload, (uint256, address, uint8));
        number = amount;
        user = recipient;

        if (choice == 1) {
            endpoint.sendCompose(stableCoinContract, _guid, 0, payload);
        } else if (choice == 2) {
            _checkBorrowerLiquidationStatus(recipient, _origin.srcEid);
        } else if (choice == 3) {
            emit LiquidationStatusReceivedOnSourceChain(amount, choice);
        } else if (choice == 4) {
            userAddressToNumberOfStablecoinsMinted[recipient] -= amount;
        } else if (choice == 5) {
            (
                uint256 amount,
                address recipient,
                uint8 choice,
                uint16 _msgType,
                uint256 extraOptionsStart,
                uint256 extraOptionsLength
            ) = decodeMessage(payload);
            user = recipient;
            number = amount;

            if (_msgType == SEND_ABA) {
                // string memory _newMessage = "Chain B says goodbye!";

                uint256 queriedUserOutstandingBalance = 1234;

                // uint256 borrowerHealthFactor = _getBorrowerHealthFactor(recipient);
                // // using high health factor so we can liquidate a user in demo
                // if (borrowerHealthFactor < 3000000000000000000) {
                //     queriedUserOutstandingBalance = userAddressToNumberOfStablecoinsMinted[recipient];
                // }

                bytes memory _options = combineOptions(
                    _origin.srcEid, SEND, payload[extraOptionsStart:extraOptionsStart + extraOptionsLength]
                );

                _lzSend(
                    _origin.srcEid,
                    abi.encode(queriedUserOutstandingBalance, recipient, 6, SEND),
                    _options,
                    MessagingFee(msg.value, 0),
                    payable(address(this))
                );

                emit ReturnMessageSent(_origin.srcEid);
            }

            emit MessageReceived(data, _origin.srcEid, _origin.sender);
        } else if (choice == 6) {
            liquidatableUsersToLiquidationAmounts[recipient] = amount;
        } else if (choice == 7) {
            // _releaseNftToLiquidator();
        }
    }

    function callStableEngineContractAndMint(address _recipient, uint256 _numberOfCoins) internal {
        IStableCoin(stableCoinContract).mint(_recipient, _numberOfCoins);
        emit MintContractCalled();
    }

    // ==========================
    // === CALCULATE MAX MINT ===
    // ==========================

    function _calculateMaxMintableByUser(address _user) internal view returns (uint256) {
        // calculate amount of stables that user can mint against their entire collateral
        uint256 totalValueOfAllCollateral = _calculateTotalValueOfUserCollateral(_user);
        uint256 availableToBorrowAtMaxCR = (totalValueOfAllCollateral * COLLATERALISATION_RATIO) / 1e18; // 50% of nft price
        uint256 maxStablecoinCanBeMinted = availableToBorrowAtMaxCR - userAddressToNumberOfStablecoinsMinted[_user];
        return maxStablecoinCanBeMinted;
    }

    function _calculateTotalValueOfUserCollateral(address _user) internal view returns (uint256) {
        uint256 totalValueOfAllCollateral = nftPriceInUsd() * numberOfNftsUserHasSupplied[_user];
        return totalValueOfAllCollateral;
    }

    function _getBorrowerHealthFactor(address _borrower) internal view returns (uint256) {
        // get borrower's borrowed tokens amount
        uint256 borrowed = userAddressToNumberOfStablecoinsMinted[_borrower]; // e.g. 500e18

        // get borower's collateral value
        uint256 totalValueOfAllCollateral = _calculateTotalValueOfUserCollateral(_borrower); // e.g. 36000e18

        // calculate health factor
        uint256 healthFactor = (totalValueOfAllCollateral / borrowed) * COLLATERALISATION_RATIO;
        return healthFactor;
    }

    function _simulateBorrowerHealthFactorAfterWithdrawal(address _borrower) internal view returns (uint256) {
        // get borrower's borrowed tokens amount
        uint256 borrowed = userAddressToNumberOfStablecoinsMinted[_borrower]; // e.g. 500e18
        uint256 borrowedPlusSingleNftValueInUsd = nftPriceInUsd();

        // get borower's collateral value
        uint256 totalValueOfAllCollateral = _calculateTotalValueOfUserCollateral(_borrower); // e.g. 36000e18

        // calculate health factor
        uint256 healthFactor = (totalValueOfAllCollateral / borrowedPlusSingleNftValueInUsd) * COLLATERALISATION_RATIO;
        return healthFactor;
    }

    // ======================
    // === NFT PRICE FEED ===
    // ======================

    function nftPriceInUsd() internal view returns (uint256) {
        // IChainlinkDataFeed nftPriceFeed = IChainlinkDataFeed(nftOracles[0]);
        // uint256 nftPrice = uint256(nftPriceFeed.latestAnswer());
        // return nftPrice * 1e10; // bring it up as chainlink returns it with 8 decimals only
        return 25000e18;
    }

    // =============================
    // === LIQUIDATION FUNCTIONS ===
    // =============================

    function sendLiquidationCheck(
        uint32 _dstEid,
        uint256 _amount,
        address _recipient,
        uint8 _choice,
        bytes calldata _options
    ) external payable returns (MessagingReceipt memory receipt) {
        bytes memory _payload = abi.encode(_amount, _recipient, _choice);
        receipt = _lzSend(_dstEid, _payload, _options, MessagingFee(msg.value, 0), payable(msg.sender));
    }

    function _checkBorrowerLiquidationStatus(address _borrower, uint32 _dstEid) internal returns (uint256) {
        // if user is liquidatable
        if (_getBorrowerHealthFactor(_borrower) < 10) {
            bytes memory _payload = abi.encode(userAddressToNumberOfStablecoinsMinted[_borrower], _borrower, 3);
            bytes memory _options =
                "0x000301001101000000000000000000000000000aae60010013030000000000000000000000000000000aae60";
            _lzSend(_dstEid, _payload, _options, MessagingFee(msg.value, 0), payable(msg.sender));
            emit AttemptedLzSendFromCheckBorrowerStatus();
        }
    }

    function _releaseNftToLiquidator() internal {}

    // =========================
    // === SETTERS & GETTERS ===
    // =========================

    function setStableCoin(address _stableCoin) external onlyOwner {
        stableCoinContract = _stableCoin;
    }

    function setNftAsCollateral(address _nftAddress, address _nftOracle, uint256 _index) external onlyOwner {
        whitelistedNFTs.push(_nftAddress);
        nftOracles.push(_nftOracle);
    }

    function setDstEidOfHomeChain(uint32 _lzDstEidOfThisChain) external onlyOwner {
        lzDstEidOfThisChain = _lzDstEidOfThisChain;
    }

    function getUserTokenIdsForAnNftCollection(address _holder, address nftCollection)
        public
        view
        returns (uint256[] memory)
    {
        return userAddressToNftCollectionTokenIds[_holder][nftCollection];
    }

    function getMaxMintableByUser(address _user) external view returns (uint256) {
        // calculate amount of stables that user can mint against their entire collateral
        return _calculateMaxMintableByUser(_user);
    }

    function getBorrowerHealthFactor(address _borrower) external view returns (uint256) {
        return _getBorrowerHealthFactor(_borrower);
    }

    // ============================
    // === NFT RECEIVE REQUIRED ===
    // ============================

    function onERC721Received(address, address, uint256, bytes memory) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ====================================
    // === lZ ENCODE & DECODE FOR A-B-A ===
    // ====================================

    function encodeMessage(
        uint256 _amount,
        address _recipient,
        uint8 _choice,
        uint16 _msgType,
        bytes memory _extraReturnOptions
    ) public pure returns (bytes memory) {
        // Get the length of _extraReturnOptions
        uint256 extraOptionsLength = _extraReturnOptions.length;

        // Encode the entire message, prepend and append the length of extraReturnOptions
        return abi.encode(
            _amount, _recipient, _choice, _msgType, extraOptionsLength, _extraReturnOptions, extraOptionsLength
        );
    }

    function decodeMessage(bytes calldata encodedMessage)
        public
        pure
        returns (
            uint256 _amount,
            address _recipient,
            uint8 _choice,
            uint16 msgType,
            uint256 extraOptionsStart,
            uint256 extraOptionsLength
        )
    {
        extraOptionsStart = 256; // Starting offset after _message, _msgType, and extraOptionsLength
        // string memory _message;
        uint16 _msgType;

        // Decode the first part of the message
        (_amount, _recipient, _choice, _msgType, extraOptionsLength) =
            abi.decode(encodedMessage, (uint256, address, uint8, uint16, uint256));

        return (_amount, _recipient, _choice, _msgType, extraOptionsStart, extraOptionsLength);
    }

    function sendABA(
        uint32 _dstEid,
        uint16 _msgType,
        uint256 _amount,
        address _recipient,
        uint8 _choice,
        bytes calldata _extraSendOptions, // gas settings for A -> B
        bytes calldata _extraReturnOptions // gas settings for B -> A
    ) external payable {
        // Encodes the message before invoking _lzSend.
        // require(bytes(_message).length <= 32, "String exceeds 32 bytes");

        if (_msgType != SEND && _msgType != SEND_ABA) {
            revert InvalidMsgType();
        }

        bytes memory options = combineOptions(_dstEid, _msgType, _extraSendOptions);

        _lzSend(
            _dstEid,
            encodeMessage(_amount, _recipient, _choice, _msgType, _extraReturnOptions),
            options,
            // Fee in native gas and ZRO token.
            MessagingFee(msg.value, 0),
            // Refund address in case of failed source message.
            payable(msg.sender)
        );

        emit MessageSent(_dstEid);
    }
}
