// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/** 
 * NftFiLoanBank Main Contract
 * @dev Implementation of Loans Project by Staking ERC721 NFT.
 * TODO: Interfact Extraction
 */
contract NftFiLoanBank{

    // Contract owner
    address private _owner;

    // Re-entrancy handler
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    /**
     * @dev Init the contract with the owner and re-entrancy state
     */
    constructor ()
    {
        _owner = msg.sender;
        _status = _NOT_ENTERED;
    }

    // Number of loans have been created
    uint256 public numOfLoans;

    // Number of loans whose status are still being able to bid
    uint256 public numOfBiddableLoans;

    // Mapping from loan id to loan struct
    mapping(uint256 => Loan) private Loans;

    // Mapping from address to loan ids whose loans have been proposed yet not beed bid
    mapping(address => uint256[]) private LoansIDPropose;

    // Mapping from lender address to loan ids whose loans have successfully beed bid
    mapping(address => uint256[]) private LoansIDLend;

    // Mapping from borrower address to loan ids whose loans have successfully been paid
    mapping(address => uint256[]) private LoansIDBorrow;

    /**
     * @dev To prevent re-entrant for the function call
     */
    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;
        _;
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }

    /* *********** */
    /* LOAN STRUCT */
    /* *********** */
    struct Loan {
        // GENERATED WHEN LOAN INIT
        // An Unique ID to identify loan, generated from the increasing number of var:numOfLoans
        uint256 ID;
        // Staked NFT address
        address tokenAddress;
        // Staked NFT original owner address
        address tokenOwnerAddress;
        // Staked NFT ID
        uint256 tokenID;
        // Loan status
        Status status;
        // Unixtimstamp to record the ending time of biding activity. When the time is up, 
        // the status would become "end" yet the loan record would still exist.
        uint256 endingBidTimestamp;
        // Amount that the asker would like to borrow in the loan.
        uint256 amount;
        // Amount that the asker would repay for this loan.
        uint256 repayAmount;
        // Unixtimestamp to identify the duration of loan repayment. Once the loan is bid,
        // the contract will record the due repayment timestamp of this loan.
        uint256 duration;

        // INIT WITH EMPTY, YET FILL UP WHEN THE LOAN IS BID.
        // Loan lender address
        address lenderAddress;
        // Unixtimestamp to record the starting timestamp of this loan
        uint256 initTimestamp;
        // Unixtimestamp to record the due repayment timestamp of this loan, 
        // comes out from initTimestamp + duration.
        uint256 endTimestamp;
    }

    // Loan Status
    // unbid : all loans will be init with status unbid when proposed
    // bid   : when a loan is bid by a lender, the status will become bid
    // end   : whenver a loan is expired from endingBidTimestamp, repaid or default
    //         (cannot repay) by the borrower, the status will finally end.
    enum Status {
        unbid,
        bid,
        end
    }

    event LoanCreated(uint256 id, address tokenAddress, address tokenOwnerAddress, 
                        uint256 tokenID, uint256 amount, uint256 repayAmount, 
                        uint256 endingBidTimestamp, uint256 duration);
    event LoanCanceled(uint256 id, address asker);
    event LoanBid(uint256 id, address lender);
    event LoanRepay(uint256 id, address borrower);


    /**
     * @dev Proposes a new loan. 
     * The endingBidTimestamp cannot be smaller than now, or return failed.
     *
     * @notice The ownership of the NFT will be transfered to the contract once the loan
     * is proposed.
     * 
     * @return loanID
     */
    function proposeLoan(address _tokenAddress, uint256 _tokenID, uint256 _amount, 
        uint256 _endingBidTimestamp, uint256 _repayAmount, uint256 _duration) 
        external nonReentrant returns (uint256) 
    {
        require(_endingBidTimestamp > block.timestamp, "Loan bid ending time error.");
        uint256 loanID = numOfLoans ++;
        IERC721(_tokenAddress).transferFrom(msg.sender, address(this), _tokenID);
        Loans[loanID].ID = loanID;
        Loans[loanID].tokenAddress = _tokenAddress;
        Loans[loanID].tokenOwnerAddress = msg.sender;
        Loans[loanID].tokenID = _tokenID;
        Loans[loanID].amount = _amount;
        Loans[loanID].endingBidTimestamp = _endingBidTimestamp;
        Loans[loanID].repayAmount = _repayAmount;
        Loans[loanID].duration = _duration;
        Loans[loanID].status = Status.unbid;
        LoansIDPropose[msg.sender].push(loanID);
        numOfBiddableLoans += 1;
        emit LoanCreated(loanID, _tokenAddress, msg.sender, _tokenID, _amount, 
                            _repayAmount, _endingBidTimestamp, _duration);
        return loanID;
    }

    /**
     * @dev Deletes an unbid loan by loan id.
     * The ownership of the staked NFT will be returned back to the original owner.
     * While the loan is being canceled, the contract will still keep the history loan,
     * so only the var:numOfBiddableLoans will be effected.
     * 
     * @notice Only when the loan is still unbid can the loan asker cancel the loan.
     */
    function cancelLoan(uint256 _id) public
    {
        Loan storage loanToCancel = Loans[_id];
        require(msg.sender == loanToCancel.tokenOwnerAddress, "Only the loan asker can cancel the loan");
        require(loanToCancel.status == Status.unbid);
        transferNFTToUser(loanToCancel.tokenAddress, loanToCancel.tokenID, address(this), 
                            loanToCancel.tokenOwnerAddress);
        Loans[_id].status = Status.end;
        numOfBiddableLoans -= 1;
        emit LoanCanceled(_id, msg.sender);
    }

    /** 
     * @dev Bids an unbid loan by lona id.
     * The lender needs to pay for the loan directly to the loan owner
     * (here we use the func:sendETHToUser).
     * If the transaction failed, the loan will not be bid.
     * When the bid is completed, the two mapper will record the loan history 
     * and reset the loan status.
     * 
     * @notice See func:sendETHToUser
     */
    function bidLoan(uint256 _id) external payable nonReentrant
    {
        Loan storage loanToBid = Loans[_id];
        uint256 nowTimestamp = block.timestamp;
        require(loanToBid.endingBidTimestamp > nowTimestamp);
        require(msg.value >= loanToBid.amount);
        bool sendSuccess = sendETHToUser(payable(loanToBid.tokenOwnerAddress), loanToBid.amount);
        require(sendSuccess);
        loanToBid.lenderAddress = msg.sender;
        loanToBid.status = Status.bid;
        loanToBid.initTimestamp = nowTimestamp;
        loanToBid.endTimestamp = nowTimestamp + loanToBid.duration;
        emit LoanBid(_id, msg.sender);
        numOfBiddableLoans -= 1;
        LoansIDLend[msg.sender].push(_id);
        LoansIDBorrow[Loans[_id].tokenOwnerAddress].push(_id);
    }
    
    /**
     * @dev The borrower repays the loan before the due time.
     * The repay activity is only allowed when the end time of the loan still not due.
     * The borrower will pay back the ETH to the lender by address. When the transaction
     * is completed, the loan status and the two mapper will all be updated. Finally, the
     * ownership of the staked NFT will be returned back to the original borrower.
     *
     * @notice See func:sendETHToUser
     * @notice The ownership of NFT will be transferred in the function.
     */
    function repayLoan(uint256 _id) external payable nonReentrant
    {
        Loan storage loanToRepay = Loans[_id];
        require(msg.value >= loanToRepay.repayAmount);
        require(block.timestamp < loanToRepay.endTimestamp);
        bool sendSuccess = sendETHToUser(payable(loanToRepay.lenderAddress), loanToRepay.repayAmount);
        require(sendSuccess);
        loanToRepay.status = Status.end;
        emit LoanRepay(_id, msg.sender);
        updateLoanList(_id, loanToRepay.lenderAddress, loanToRepay.tokenOwnerAddress);
        transferNFTToUser(loanToRepay.tokenAddress, loanToRepay.tokenID, address(this), loanToRepay.tokenOwnerAddress);
    }
    
    /**
     * @dev Transfers ERC721 NFT token to the given address.
     */
    function transferNFTToUser(address _tokenAddress, uint256 _tokenID, address _from, address _to) 
    private
    {
        IERC721(_tokenAddress).transferFrom(_from, _to, _tokenID);
    }

    /**
     * @dev Transfers ETH to the given address.
     * Here we use function "call" for better handling. It is now the most recommended 
     * way to transfer ETH.
     * 
     * @return Status of transaction
     */
    function sendETHToUser(address payable _to, uint256 value) private returns (bool)
    {
        (bool callSuccess, ) = _to.call{value: value}("");
        return callSuccess;
    }

    /**
     * @dev Updates the loan list
     * For we have two Mapper to record the loan which have been bid, we need to update
     * them when the loan is repaied/expired/default.
     * 
     * @notice As there is only pop/delete function in solidity, we utilize swap and pop
     * function to remove the item, so the final ID list will probably be unordered one.
     */
    function updateLoanList(uint256 _loanID, address _lenderAddress, address _borrowerAddress) private
    {
        if (LoansIDLend[_lenderAddress].length > 1)
        {
            LoansIDLend[_lenderAddress][_loanID] = 
                LoansIDLend[_lenderAddress][LoansIDLend[_lenderAddress].length - 1];
        }
        LoansIDLend[_lenderAddress].pop();
        if (LoansIDBorrow[_borrowerAddress].length > 1)
        {
            LoansIDBorrow[_borrowerAddress][_loanID] = 
                LoansIDBorrow[_borrowerAddress][LoansIDBorrow[_borrowerAddress].length - 1];
        }
        LoansIDBorrow[_borrowerAddress].pop();
    }


    /**
     * @dev Retrives the biddable loans by status.
     */
    function getBiddableLoans() public view returns (Loan[] memory)
    {
        Loan[] memory biddableLoans = new Loan[](numOfBiddableLoans);
        uint256 loanIndex = 0;
        for(uint i = 0; i < numOfLoans; i++)
        {
            if(Loans[i].status == Status.unbid)
            {
                biddableLoans[loanIndex] = Loans[i];
                loanIndex ++;
            }
        }
        return (biddableLoans);
    }

    /** 
     * @dev Retrives the detail information of the loan by loanID.
     */
    function getLoanDetail(uint256 _id) public view returns(Loan memory)
    {
        return Loans[_id];
    }

    /**
     * @dev Retrives all loans whose status are unbid by the asker address.
     */
    function getLoansByAsker(address _askerAddress) public view returns(Loan[] memory)
    {
        uint256[] memory askerLoansID = LoansIDPropose[_askerAddress];
        Loan[] memory proposedLoans = new Loan[](askerLoansID.length);
        for (uint i = 0; i < askerLoansID.length; i++)
        {
            proposedLoans[i] = Loans[askerLoansID[i]];
        }
        return proposedLoans;
    }

    /**
     * @dev Retrives all loans whose status are bid by the lender address.
     */
    function getLoansByLender(address _lenderAddress) public view returns(Loan[] memory)
    {
        uint256[] memory lenderLoansID = LoansIDLend[_lenderAddress];
        Loan[] memory lenderLoans = new Loan[](lenderLoansID.length);
        for (uint i = 0; i < lenderLoansID.length; i++)
        {
            lenderLoans[i] = Loans[lenderLoansID[i]];
        }
        return lenderLoans;
    }

    /**
     * @dev Retrives all loans whose status are bid by the borrower address.
     */
    function getLoansByBorrower(address _borrowerAddress) public view returns(Loan[] memory)
    {
        uint256[] memory borrowerLoansID = LoansIDBorrow[_borrowerAddress];
        Loan[] memory borrowerLoans = new Loan[](borrowerLoansID.length);
        for (uint i = 0; i < borrowerLoansID.length; i++)
        {
            borrowerLoans[i] = Loans[borrowerLoansID[i]];
        }
        return borrowerLoans;
    }

    /**
     * @dev Updates status for all the exired loan by their endingBidTimestamp.
     * 
     * TODO: For there is not any scheduler function for the blockchain, we can now only
     * rely on the front-end to do the function call for update the loan status.
     */
    function updateExpiredLoanStatus() public
    {
        uint256 nowTimestamp = block.timestamp;
        uint256 expiredLoans = 0;
        for (uint i = 0; i < numOfLoans; i++) 
        {
            if (Loans[i].status == Status.unbid)
            {
                if (Loans[i].endingBidTimestamp < nowTimestamp)
                {
                    Loans[i].status = Status.end;
                    transferNFTToUser(Loans[i].tokenAddress, Loans[i].tokenID, address(this), 
                                        Loans[i].tokenOwnerAddress);
                    expiredLoans ++;
                }
            }
        }
        numOfBiddableLoans -= expiredLoans;
    }

    /**
     * @dev Updates status for all the default loan by their endTimestamp.
     * When the borrowers cannot repay the amount they have proposed, the
     * ownership of staked NFT will be transferred to the lender of the loan.
     *
     * @notice The ownership of the NFT will be automatically transferred when
     * the loan is default.
     */
    function updateDefaultLoans() public
    {
        uint256 nowTimestamp = block.timestamp;
        for (uint i = 0; i < numOfLoans; i++) 
        {
            if (Loans[i].status == Status.bid)
            {
                if (Loans[i].endTimestamp < nowTimestamp)
                {
                    Loans[i].status = Status.end;
                    transferNFTToUser(Loans[i].tokenAddress, Loans[i].tokenID, address(this), 
                                        Loans[i].lenderAddress);
                }
            }
        }
    }

    
}
