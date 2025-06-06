// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IImpactProductNFT.sol";

// Define struct at file level so it can be imported by tests
struct ImpactProductData {
    string category;
    string location;
    uint256 startDate;
    uint256 endDate;
    string beneficiaries;
    uint256 baseImpactValue;
    uint256 listingPrice;
    string metadataURI;
}

/**
 * @title ImpactProductFactory
 * @author Regen Bazaar
 * @notice Factory contract for creating Impact Products from real-world impact data
 * @custom:security-contact security@regenbazaar.com
 */
contract ImpactProductFactory is AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant CREATOR_ROLE = keccak256("CREATOR_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    
    IImpactProductNFT public impactProductNFT;

    address public platformFeeReceiver;
    uint96 public platformRoyaltyBps = 500; 
    uint96 public defaultCreatorRoyaltyBps = 500; 

    struct ImpactParams {
        string category;
        uint256 baseMultiplier;  
        bool verified;           
    }
    mapping(string => ImpactParams) public impactParameters;
    string[] public impactCategories;

    event ImpactProductCreated(
        uint256 indexed tokenId, 
        address indexed creator, 
        string category,
        uint256 impactValue,
        uint256 price,
        bool verified
    );
    
    event CategoryAdded(string category, uint256 baseMultiplier);
    event CategoryRemoved(string category);
    event ImpactCalculationParamsUpdated(string category, uint256 baseMultiplier);
    
    /**
     * @notice Constructor for the factory contract
     * @param impactNFT Address of the ImpactProductNFT contract
     * @param platformWallet Address to receive platform fees and royalties
     */
    constructor(address impactNFT, address platformWallet) {
        require(impactNFT != address(0), "Invalid NFT contract");
        require(platformWallet != address(0), "Invalid platform wallet");
        
        impactProductNFT = IImpactProductNFT(impactNFT);
        platformFeeReceiver = platformWallet;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(CREATOR_ROLE, msg.sender);
        _grantRole(VERIFIER_ROLE, msg.sender);

        _addImpactCategory("Community gardens", 1000);
        _addImpactCategory("Tree preservation", 2500);
        _addImpactCategory("Eco tourism", 1500);
        _addImpactCategory("Educational programs", 2000);
        _addImpactCategory("Wildlife Conservation", 3000);
        _addImpactCategory("CO2 Emissions Reduction", 3500);
        _addImpactCategory("Waste Management", 1200);
    }
    
    /**
     * @notice Pause factory operations
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause factory operations
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Create a new impact product from real-world impact data
     * @param data Struct containing all impact product data
     * @return tokenId ID of the newly created impact product
     */
    function createImpactProduct(
        ImpactProductData memory data
    )
        external
        onlyRole(CREATOR_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 tokenId)
    {
        require(data.baseImpactValue > 0, "Impact value must be positive");
        require(data.listingPrice > 0, "Price must be positive");
        require(bytes(data.category).length > 0, "Category cannot be empty");
        require(_isCategorySupported(data.category), "Unsupported impact category");

        uint256 finalImpactValue = _calculateImpactValue(data.category, data.baseImpactValue);

        IImpactProductNFT.ImpactData memory impactData = IImpactProductNFT.ImpactData({
            category: data.category,
            impactValue: finalImpactValue,
            location: data.location,
            startDate: data.startDate,
            endDate: data.endDate,
            beneficiaries: data.beneficiaries,
            verified: false,
            metadataURI: data.metadataURI
        });

        tokenId = impactProductNFT.createImpactProduct(
            msg.sender,
            impactData,
            data.listingPrice,
            msg.sender,
            defaultCreatorRoyaltyBps
        );
        
        emit ImpactProductCreated(
            tokenId,
            msg.sender,
            data.category,
            finalImpactValue,
            data.listingPrice, 
            false 
        );
        
        return tokenId;
    }
    
    /**
     * @notice Verify an impact product after validation
     * @param tokenId ID of the token to verify
     * @param validators Array of addresses of validators who confirmed this impact
     * @return success Boolean indicating if the operation was successful
     */
    function verifyImpactProduct(uint256 tokenId, address[] calldata validators)
        external
        onlyRole(VERIFIER_ROLE)
        nonReentrant
        returns (bool success)
    {
        return impactProductNFT.verifyToken(tokenId, validators);
    }
    
    /**
     * @notice Calculate the impact value for a specific category and base value
     * @param category Impact category
     * @param baseValue Raw impact value before applying multipliers
     * @return finalValue The final calculated impact value
     */
    function calculateImpactValue(string calldata category, uint256 baseValue)
        external
        view
        returns (uint256 finalValue)
    {
        require(_isCategorySupported(category), "Unsupported impact category");
        return _calculateImpactValue(category, baseValue);
    }
    
    /**
     * @notice Add a new impact category
     * @param category Name of the new category
     * @param baseMultiplier Base multiplier for the category (in basis points)
     */
    function addImpactCategory(string calldata category, uint256 baseMultiplier)
        external
        onlyRole(ADMIN_ROLE)
    {
        _addImpactCategory(category, baseMultiplier);
    }
    
    /**
     * @notice Remove an impact category
     * @param category Name of the category to remove
     */
    function removeImpactCategory(string calldata category)
        external
        onlyRole(ADMIN_ROLE)
    {
        require(_isCategorySupported(category), "Category does not exist");

        for (uint256 i = 0; i < impactCategories.length; i++) {
            if (keccak256(bytes(impactCategories[i])) == keccak256(bytes(category))) {
                impactCategories[i] = impactCategories[impactCategories.length - 1];
                impactCategories.pop();
                delete impactParameters[category];
                emit CategoryRemoved(category);
                break;
            }
        }
    }
    
    /**
     * @notice Update impact calculation parameters for a category
     * @param category Impact category
     * @param baseMultiplier New base multiplier (in basis points)
     */
    function updateImpactParams(string calldata category, uint256 baseMultiplier)
        external
        onlyRole(ADMIN_ROLE)
    {
        require(_isCategorySupported(category), "Category does not exist");
        require(baseMultiplier > 0, "Multiplier must be positive");
        _tempCategory = category;
        _calculateAndStoreImpactParams(_tempCategory, baseMultiplier, false);
        emit ImpactCalculationParamsUpdated(category, baseMultiplier);
    }
    
    /**
     * @notice Update platform royalty settings
     * @param newRoyaltyBps New platform royalty in basis points
     */
    function updatePlatformRoyalty(uint96 newRoyaltyBps)
        external
        onlyRole(ADMIN_ROLE)
    {
        require(newRoyaltyBps <= 2000, "Platform royalty too high");
        platformRoyaltyBps = newRoyaltyBps;
    }
    
    /**
     * @notice Update default creator royalty settings
     * @param newRoyaltyBps New creator royalty in basis points
     */
    function updateDefaultCreatorRoyalty(uint96 newRoyaltyBps)
        external
        onlyRole(ADMIN_ROLE)
    {
        require(newRoyaltyBps <= 2000, "Creator royalty too high");
        defaultCreatorRoyaltyBps = newRoyaltyBps;
    }
    
    /**
     * @notice Update platform fee receiver
     * @param newReceiver New platform fee receiver address
     */
    function updatePlatformFeeReceiver(address newReceiver)
        external
        onlyRole(ADMIN_ROLE)
    {
        require(newReceiver != address(0), "Invalid address");
        platformFeeReceiver = newReceiver;
    }
    
    /**
     * @notice Grant creator role to an address
     * @param creator Address to grant creator role
     */
    function grantCreatorRole(address creator)
        external
        onlyRole(ADMIN_ROLE)
    {
        _grantRole(CREATOR_ROLE, creator);
    }
    
    /**
     * @notice Revoke creator role from an address
     * @param creator Address to revoke creator role
     */
    function revokeCreatorRole(address creator)
        external
        onlyRole(ADMIN_ROLE)
    {
        _revokeRole(CREATOR_ROLE, creator);
    }
    
    /**
     * @notice Get all supported impact categories
     * @return Array of supported category names
     */
    function getSupportedCategories()
        external
        view
        returns (string[] memory)
    {
        return impactCategories;
    }
    
    /**
     * @notice Internal function to add an impact category
     * @param category Name of the category
     * @param baseMultiplier Base multiplier for the category
     */
    function _addImpactCategory(string memory category, uint256 baseMultiplier) internal {
        require(bytes(category).length > 0, "Category cannot be empty");
        require(baseMultiplier > 0, "Multiplier must be positive");
        require(!_isCategorySupported(category), "Category already exists");
        impactCategories.push(category);
        _calculateAndStoreImpactParams(category, baseMultiplier, false);
        
        emit CategoryAdded(category, baseMultiplier);
    }
    
    /**
     * @notice Internal function to check if a category is supported
     * @param category Name of the category to check
     * @return isSupported True if the category is supported
     */
    function _isCategorySupported(string memory category) internal view returns (bool) {
        return impactParameters[category].baseMultiplier > 0;
    }
    
    /**
     * @notice Internal function to calculate impact value with category multiplier
     * @param category Impact category
     * @param baseValue Raw impact value
     * @return calculatedValue The calculated impact value
     */
    function _calculateImpactValue(string memory category, uint256 baseValue)
        internal
        view
        returns (uint256 calculatedValue)
    {
        ImpactParams memory params = impactParameters[category];
        calculatedValue = (baseValue * params.baseMultiplier) / 10000; 
        return calculatedValue;
    }

    // Use temporary storage to reduce stack usage
    string _tempCategory;

    // Then define a helper function
    function _calculateAndStoreImpactParams(string memory cat, uint256 mult, bool verified) private {
        impactParameters[cat] = ImpactParams({
            category: cat,
            baseMultiplier: mult,
            verified: verified
        });
    }
}