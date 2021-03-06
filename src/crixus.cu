/***********************************\
 *
 * TODO LIST:
 * - Version 0.6:
 *   - in/outflow/moving boundary option
 *   - read/write config file
 *   - replace uf4 by uf3 (class with float[3])
 *   - do more calculations using the vector_math.h library
 *   - while doing calculations on kernel check
 *     files on host and maybe read them already
 *   - clean up code (free norm, ep when they
 *     are no longer needed and not at the end)
 *   - refactor the codes so that crixus.cu is split into functions
 * - Version 0.7:
 *   - CSG for volume computation
 *
\***********************************/

#ifndef CRIXUS_CU
#define CRIXUS_CU

#include "crixus.h"
#include "return.h"
#include "crixus_d.cuh"
#include "lock.cuh"
#include "vector_math.h"
#include "crixus_d.cu"

using namespace std;

int crixus_main(int argc, char** argv){
  //host
  cout << endl;
  cout << "\t**************************************" << endl;
  cout << "\t*                                    *" << endl;
  cout << "\t*             C R I X U S            *" << endl;
  cout << "\t*                                    *" << endl;
  cout << "\t**************************************" << endl;
  cout << "\t* Version     : 0.5                  *" << endl;
  cout << "\t* Date        : 27.03.2014           *" << endl;
  cout << "\t* Author      : Arno Mayrhofer       *" << endl;
  cout << "\t* Contributors: Christophe Kassiotis *" << endl;
  cout << "\t*               F-X Morel            *" << endl;
  cout << "\t*               Martin Ferrand       *" << endl;
  cout << "\t*               Agnes Leroy          *" << endl;
  cout << "\t*               Antoine Joly         *" << endl;
  cout << "\t*               Giuseppe Bilotta     *" << endl;
  cout << "\t*               Eugenio Rustico      *" << endl;
  cout << "\t**************************************" << endl;
  cout << endl;
  float m_v_floats[12];
  unsigned int through;
  short attribute;
  unsigned int num_of_facets;
  const unsigned int bitPerUint = 8*sizeof(unsigned int);

  if(argc==1){
    cout << "No configuration file specified." << endl;
    cout << "Correct use: crixus filename" << endl;
    cout << "Example use: crixus box.ini" << endl;
    return NO_FILE;
  }
  else if(argc>2){
    cout << "Ignoring additional arguments after configuration file." << endl;
  }
  string configfname = argv[1];
  INIReader config(configfname);

  if (config.ParseError() < 0) {
    std::cout << "Can't load configuration file " << configfname << endl;;
    return CANT_READ_CONFIG;
  }
  string fname = config.Get("mesh", "stlfile", "UNKNOWN");

  //looking for cuda devices without timeout
  cout << "Selecting GPU ...";
  int dcount, maxblock=0, maxthread;
  maxthread = threadsPerBlock;
  bool found = false;
  CUDA_SAFE_CALL( cudaGetDeviceCount(&dcount) );
  int chosenDevice = config.GetInteger("system", "gpu-id", -1);
  chosenDevice = min(dcount, max(-1, chosenDevice));
  const int start = chosenDevice < 0 ? 0 : -1;
  for (int i=start; i<dcount; i++){
    int j = i;
    if (i == -1)
      j = chosenDevice;
    cudaDeviceProp prop;
    CUDA_SAFE_CALL( cudaGetDeviceProperties(&prop,j) );
    if(!prop.kernelExecTimeoutEnabled){
      found = true;
      CUDA_SAFE_CALL( cudaSetDevice(j) );
      maxthread = prop.maxThreadsPerBlock;
      maxblock  = prop.maxGridSize[0];
      cout << " Id: " << j << " (" << maxthread << ", " << maxblock << ") ...";
      if(maxthread < threadsPerBlock){
        cout << " [FAILED]" << endl;
        return MAXTHREAD_TOO_BIG;
      }
      cout << " [OK]" << endl;
      break;
    }
  }
  if(!found){
    cudaDeviceProp prop;
    CUDA_SAFE_CALL( cudaGetDeviceProperties(&prop,0) );
    CUDA_SAFE_CALL( cudaSetDevice(0) );
    maxthread = prop.maxThreadsPerBlock;
    maxblock  = prop.maxGridSize[0];
    cout << " Id: " << 0 << " (" << maxthread << ", " << maxblock << ") ...";
    if(maxthread < threadsPerBlock){
      cout << " [FAILED]" << endl;
      return MAXTHREAD_TOO_BIG;
    }
    cout << " [OK]" << endl;
    cout << "\n\tWARNING:" << endl;
    cout << "\tCould not find GPU without timeout." << endl;
    cout << "\tIf execution terminates with timeout reduce gres.\n" << endl;
  }
  if(maxthread != threadsPerBlock){
    cout << "\n\tINFORMATION:" << endl;
    cout << "\tthreadsPerBlock is not equal to maximum number of available threads.\n" << endl;
  }

  //Reading file
  cout << "Opening file " << fname << " ...";
  ifstream stl_file (fname.c_str(), ios::in);
  if(!stl_file.is_open()){
    cout << " [FAILED]" << endl;
    return FILE_NOT_OPEN;
  }
  cout << " [OK]" << endl;

  float dr = config.GetReal("mesh", "dr", -1);
  cout << "Mesh size: " << dr << endl;

  cout << "Checking whether stl file is not ASCII ...";
  fflush(stdout);
  bool issolid = true;
  char header[6] = "solid";
  for (int i=0; i<5; i++){
    char dum;
    stl_file.read((char *)&dum, sizeof(char));
    if(dum!=header[i]){
      issolid = false;
      break;
    }
  }
  if(issolid){
    cout << " [FAILED]" << endl;
    stl_file.close();
    return STL_NOT_BINARY;
  }
  stl_file.close();
  cout << " [OK]" << endl;

  // reopen file in binary mode
  stl_file.open(fname.c_str(), ios::in | ios::binary);

  // read header
  for (int i=0; i<20; i++){
    float dum;
    stl_file.read((char *)&dum, sizeof(float));
  }
  // get number of facets
  stl_file.read((char *)&num_of_facets, sizeof(int));
  cout << "Reading " << num_of_facets << " facets ...";
  fflush(stdout);

  // define variables
  vector< vector<float> > pos;
  vector< vector<float> > all_vert_pos;
  vector< vector<float> > norm;
  vector< vector<float> >::iterator it, jt;
  vector< vector<unsigned int> > epv;
  vector< vector<unsigned int> > init_epv;
  unsigned int nvert, nbe;
  vector<unsigned int> idum;
  vector<float> ddum;
  ddum.resize(3, 0.0);
  idum.resize(3, 0);

  // read data
  through = 0;
  float xmin = 1e10, xmax = -1e10;
  float ymin = 1e10, ymax = -1e10;
  float zmin = 1e10, zmax = -1e10;
  while ((through < num_of_facets) & (!stl_file.eof()))
  {
    for (int i=0; i<12; i++)
    {
      stl_file.read((char *)&m_v_floats[i], sizeof(float));
    }
    for(int i=0;i<3;i++) ddum[i] = (float)m_v_floats[i];
    norm.push_back(ddum);
    // save the three vertices in an array
    for(int j=0;j<3;j++){
      for(int i=0;i<3;i++){
        ddum[i] = (float)m_v_floats[i+3*(j+1)];
      }
      all_vert_pos.push_back(ddum);
      idum[j]=through*3 + j;
      xmin = (xmin > ddum[0]) ? ddum[0] : xmin;
      xmax = (xmax < ddum[0]) ? ddum[0] : xmax;
      ymin = (ymin > ddum[1]) ? ddum[1] : ymin;
      ymax = (ymax < ddum[1]) ? ddum[1] : ymax;
      zmin = (zmin > ddum[2]) ? ddum[2] : zmin;
      zmax = (zmax < ddum[2]) ? ddum[2] : zmax;
    }
    init_epv.push_back(idum);
    stl_file.read((char *)&attribute, sizeof(short));
    through++;
  }
  remove_duplicate_vertices(all_vert_pos, init_epv, pos, epv, dr);
  all_vert_pos.clear();
  init_epv.clear();
  stl_file.close();
  if(num_of_facets != norm.size()){
    cout << " [FAILED]" << endl;
    return READ_ERROR;
  }
  nvert = pos.size();
  nbe   = norm.size();
  //create and copy vectors to arrays
  uf4 *norma, *posa;
  float *vola, *surf;
  ui4 *ep;
  norma = new uf4   [nbe];
  posa  = new uf4   [nvert+nbe];
  vola  = new float [nvert];
  surf  = new float [nbe]; //AM-TODO: could go to norma[3]
  ep    = new ui4   [nbe];
  for(unsigned int i=0; i<max(nvert,nbe); i++){
    if(i<nbe){
      for(int j=0; j<3; j++){
        norma[i].a[j] = norm[i][j];
        ep[i].a[j] = epv[i][j];
      }
    }
    if(i<nvert){
      for(int j=0; j<3; j++)
        posa[i].a[j] = pos[i][j];
      vola[i] = 0.;
    }
  }
  //cuda arrays
  // starting indices of each cell
  int *cell_idx_d;
  // current index of boundary element for a cell
  int *cur_cell_idx_d;
  // post sort arrays
  uf4 *norm_d;
  uf4 *pos_d;
  ui4 *ep_d;
  float *surf_d;
  // pre sort arrays
  uf4 *pre_norm_d;
  uf4 *pre_pos_d;
  ui4 *pre_ep_d;
  float *pre_surf_d;
  // extent of the domain
  uf4 dmin = {xmin,ymin,zmin,0.};
  uf4 dmax = {xmax,ymax,zmax,0.};
  // epsilon value
  float eps=dr/(float)gres*1e-4;

  // computing number of grid cells in each direction
  // the grid size is 3 dr
  ui4 gridn;
  gridn.a[0] = max((int)((xmax-xmin)/dr/3.0),1);
  gridn.a[1] = max((int)((ymax-ymin)/dr/3.0),1);
  gridn.a[2] = max((int)((zmax-zmin)/dr/3.0),1);
  gridn.a[3] = gridn.a[0]*gridn.a[1]*gridn.a[2];
  uf4 griddr;
  for(unsigned int j=0; j<3; j++)
    griddr.a[j] = (dmax.a[j] - dmin.a[j] + eps)/(float)gridn.a[j];

  CUDA_SAFE_CALL( cudaMemcpyToSymbol(crixus_d::griddr, &griddr, sizeof(uf4  )) );
  CUDA_SAFE_CALL( cudaMemcpyToSymbol(crixus_d::gridn , &gridn , sizeof(ui4  )) );
  CUDA_SAFE_CALL( cudaMemcpyToSymbol(crixus_d::eps   , &eps   , sizeof(float)) );
  CUDA_SAFE_CALL( cudaMemcpyToSymbol(crixus_d::dmin  , &dmin  , sizeof(uf4  )) );
  CUDA_SAFE_CALL( cudaMemcpyToSymbol(crixus_d::dmax  , &dmax  , sizeof(uf4  )) );
  CUDA_SAFE_CALL( cudaMemcpyToSymbol(crixus_d::dr    , &dr    , sizeof(float)) );

  CUDA_SAFE_CALL( cudaMalloc((void **) &cell_idx_d    ,(gridn.a[3]+1)*sizeof(int  )) );
  CUDA_SAFE_CALL( cudaMalloc((void **) &cur_cell_idx_d,(gridn.a[3]+1)*sizeof(int  )) );
  CUDA_SAFE_CALL( cudaMalloc((void **) &norm_d        ,           nbe*sizeof(uf4  )) );
  CUDA_SAFE_CALL( cudaMalloc((void **) &pos_d         ,   (nvert+nbe)*sizeof(uf4  )) );
  CUDA_SAFE_CALL( cudaMalloc((void **) &ep_d          ,           nbe*sizeof(ui4  )) );
  CUDA_SAFE_CALL( cudaMalloc((void **) &surf_d        ,           nbe*sizeof(float)) );
  CUDA_SAFE_CALL( cudaMalloc((void **) &pre_norm_d    ,           nbe*sizeof(uf4  )) );
  CUDA_SAFE_CALL( cudaMalloc((void **) &pre_pos_d     ,   (nvert+nbe)*sizeof(uf4  )) );
  CUDA_SAFE_CALL( cudaMalloc((void **) &pre_ep_d      ,           nbe*sizeof(ui4  )) );
  CUDA_SAFE_CALL( cudaMalloc((void **) &pre_surf_d        ,           nbe*sizeof(float)) );
  CUDA_SAFE_CALL( cudaMemcpy((void *) pre_norm_d,(void *) norma,         nbe*sizeof(uf4  ), cudaMemcpyHostToDevice) );
  CUDA_SAFE_CALL( cudaMemcpy((void *) pre_pos_d ,(void *) posa , (nvert+nbe)*sizeof(uf4  ), cudaMemcpyHostToDevice) );
  CUDA_SAFE_CALL( cudaMemcpy((void *) pre_ep_d  ,(void *) ep   ,         nbe*sizeof(ui4  ), cudaMemcpyHostToDevice) );
  cout << " [OK]" << endl;
  cout << "\n\tInformation:" << endl;
  cout << "\tOrigin of domain:           \t(" << xmin << ", " << ymin << ", " << zmin << ")\n";
  cout << "\tSize of domain:             \t(" << xmax-xmin << ", " << ymax-ymin << ", " << zmax-zmin << ")\n";
  cout << "\tNumber of vertices:         \t" << nvert << endl;
  cout << "\tNumber of boundary elements:\t" << nbe << "\n\n";

  int numThreads, numBlocks;
  numThreads = threadsPerBlock;
  numBlocks = (int) ceil((float)nbe/(float)numThreads);
  numBlocks = min(numBlocks,maxblock);

  if (config.GetBoolean("mesh", "swap_normals", false)) {
    cout << "Swapping normals ...";
    fflush(stdout);

    crixus_d::swap_normals<<<numBlocks, numThreads>>> (pre_norm_d, nbe);

    cout << " [OK]" << endl;
  }
  cout << endl;

  //calculate surface and position of boundary elements
  cout << "Calculating surface and position of boundary elements ...";
  fflush(stdout);

  Lock lock;
  float xminp = 1e10, xminn = 1e10;
  float nminp = 0., nminn = 0.;
  float *xminp_d, *xminn_d;
  float *nminp_d, *nminn_d;
  CUDA_SAFE_CALL( cudaMalloc((void **) &xminp_d, sizeof(float)) );
  CUDA_SAFE_CALL( cudaMalloc((void **) &xminn_d, sizeof(float)) );
  CUDA_SAFE_CALL( cudaMalloc((void **) &nminp_d, sizeof(float)) );
  CUDA_SAFE_CALL( cudaMalloc((void **) &nminn_d, sizeof(float)) );
  CUDA_SAFE_CALL( cudaMemcpy(xminp_d, &xminp, sizeof(float), cudaMemcpyHostToDevice) );
  CUDA_SAFE_CALL( cudaMemcpy(xminn_d, &xminn, sizeof(float), cudaMemcpyHostToDevice) );
  CUDA_SAFE_CALL( cudaMemcpy(nminp_d, &nminp, sizeof(float), cudaMemcpyHostToDevice) );
  CUDA_SAFE_CALL( cudaMemcpy(nminn_d, &nminn, sizeof(float), cudaMemcpyHostToDevice) );

  crixus_d::set_bound_elem<<<numBlocks, numThreads>>> (pre_pos_d, pre_norm_d, pre_surf_d, pre_ep_d, nbe, xminp_d, xminn_d, nminp_d, nminn_d, lock, nvert);

  CUDA_SAFE_CALL( cudaMemcpy(&xminp, xminp_d, sizeof(float), cudaMemcpyDeviceToHost) );
  CUDA_SAFE_CALL( cudaMemcpy(&xminn, xminn_d, sizeof(float), cudaMemcpyDeviceToHost) );
  CUDA_SAFE_CALL( cudaMemcpy(&nminp, nminp_d, sizeof(float), cudaMemcpyDeviceToHost) );
  CUDA_SAFE_CALL( cudaMemcpy(&nminn, nminn_d, sizeof(float), cudaMemcpyDeviceToHost) );
  cudaFree (xminp_d);
  cudaFree (xminn_d);
  cudaFree (nminp_d);
  cudaFree (nminn_d);
  //host
  cout << " [OK]" << endl;

  //sorting boundary elements according to cell and computing cell starting indices
  cout << "Sorting boundary elements and computing indices ...";
  fflush(stdout);

  crixus_d::init_cell_idx<<<numBlocks, numThreads>>> (cell_idx_d, cur_cell_idx_d);

  crixus_d::count_cell_bes<<<numBlocks, numThreads>>> (pre_pos_d, cell_idx_d, nbe, nvert);

  crixus_d::add_up_indices<<<1,1>>> (cell_idx_d, cur_cell_idx_d);

  crixus_d::sort_bes<<<numBlocks, numThreads>>> (pre_pos_d, pos_d, pre_norm_d, norm_d, pre_ep_d, ep_d, pre_surf_d, surf_d, cell_idx_d, cur_cell_idx_d, nbe, nvert);

  CUDA_SAFE_CALL( cudaMemcpy((void *) posa,(void *) pos_d  , (nvert+nbe)*sizeof(uf4  ), cudaMemcpyDeviceToHost) );
  CUDA_SAFE_CALL( cudaMemcpy((void *) surf,(void *) surf_d ,         nbe*sizeof(float), cudaMemcpyDeviceToHost) );
  CUDA_SAFE_CALL( cudaMemcpy((void *) norma,(void *) norm_d, nbe*sizeof(uf4), cudaMemcpyDeviceToHost) );

  cudaFree (pre_pos_d);
  cudaFree (pre_norm_d);
  cudaFree (pre_ep_d);
  cudaFree (pre_surf_d);
  cudaFree (cur_cell_idx_d);

  cout << " [OK]" << endl;

  cout << "\n\tNormals information:" << endl;
  cout << "\tPositive (n.(0,0,1)) minimum z: " << xminp << " (" << nminp << ")\n";
  cout << "\tNegative (n.(0,0,1)) minimum z: " << xminn << " (" << nminn << ")\n\n";
  if(fabs(nminp) < 1e-6 && fabs(nminn) < 1e-6 && fabs(xminp-1e10) < 1e-6 && fabs(xminn-1e10) < 1e-6){
    cout << "\t=====================================================" << endl;
    cout << "\t!!! WARNING !!!" << endl;
    cout << "\tCould not read normals properly." << endl;
    cout << "\tMaybe a Blender STL file? Save with ParaView instead." << endl;
    cout << "\t=====================================================\n" << endl;
  }

  //periodicity
  bool per[3] = {false, false, false};
  int *newlink, *newlink_h;
  newlink_h = new int[nvert];
  CUDA_SAFE_CALL( cudaMalloc((void **) &newlink, nvert*sizeof(float)) );
  for(unsigned int idim=0; idim<3; idim++){
    string pstring = (idim==0) ? "x" : ((idim==1) ? "y" : "z");

    if (config.GetBoolean("periodicity", pstring, false)) {
      per[idim] = true;
      cout << "Updating links for " << pstring << "-periodicity ...";
      fflush(stdout);
      for(unsigned int i=0; i<nvert; i++)
        newlink_h[i] = -1;
      CUDA_SAFE_CALL( cudaMemcpy((void *) newlink, (void *) newlink_h, nvert*sizeof(int)   , cudaMemcpyHostToDevice) );
      numBlocks = (int) ceil((float)max(nvert,nbe)/(float)numThreads);
      numBlocks = min(numBlocks,maxblock);

      crixus_d::find_links <<<numBlocks, numThreads>>> (pos_d, nvert, newlink, idim);
      crixus_d::periodicity_links<<<numBlocks,numThreads>>>(pos_d, ep_d, nvert, nbe, newlink, idim);

      CUDA_SAFE_CALL( cudaMemcpy((void *) posa,(void *) pos_d, (nvert+nbe)*sizeof(uf4), cudaMemcpyDeviceToHost) );
      //if(err!=0) return err;
      //host
      cout << " [OK]" << endl;
    }
  }
  CUDA_SAFE_CALL( cudaMemcpy((void *) ep  ,(void *) ep_d ,         nbe*sizeof(ui4), cudaMemcpyDeviceToHost) );
  CUDA_SAFE_CALL( cudaFree(newlink) );
  delete [] newlink_h;

  //calculate volume of vertex particles
  cout << "\nCalculating volume of vertex particles ...";
  fflush(stdout);
  int *trisize, *trisize_h;
  float *vol_d;
  trisize_h = new int[nvert];
  for(unsigned int i=0; i<nvert; i++)
    trisize_h[i] = 0;
  CUDA_SAFE_CALL( cudaMalloc((void **) &trisize, nvert*sizeof(int  )) );
  CUDA_SAFE_CALL( cudaMalloc((void **) &vol_d  , nvert*sizeof(float)) );
  CUDA_SAFE_CALL( cudaMemcpy((void *) trisize, (void *) trisize_h, nvert*sizeof(int) , cudaMemcpyHostToDevice) );
  CUDA_SAFE_CALL( cudaMemcpyToSymbol(crixus_d::per, &per, 3*sizeof(bool)) );
  numBlocks = (int) ceil((float)nvert/(float)numThreads);
  numBlocks = min(numBlocks,maxblock);
  delete [] trisize_h;

  const bool zeroOpen = config.GetBoolean("mesh", "zeroOpen", false);

  crixus_d::calc_trisize <<<numBlocks, numThreads>>> (ep_d, trisize, nbe);
#ifndef bdebug
  crixus_d::calc_vert_volume <<<numBlocks, numThreads>>> (pos_d, norm_d, ep_d, vol_d, trisize, cell_idx_d, nvert, nbe, zeroOpen);
#else
  uf4 *debug, *debug_d;
  int debugs = pow((gres*2+1),3);
  float *debugp, *debugp_d;
  debugp = new float [100];
  debug = new uf4[debugs];
  CUDA_SAFE_CALL( cudaMalloc((void **) &debug_d, debugs*sizeof(uf4)) );
  CUDA_SAFE_CALL( cudaMalloc((void **) &debugp_d, 100*sizeof(float)) );

  crixus_d::calc_vert_volume <<<numBlocks, numThreads>>> (pos_d, norm_d, ep_d, vol_d, trisize, cell_idx_d, nvert, nbe, zeroOpen, debug_d, debugp_d);

  CUDA_SAFE_CALL( cudaMemcpy((void*) debug, (void*) debug_d, debugs*sizeof(uf4), cudaMemcpyDeviceToHost) );
  CUDA_SAFE_CALL( cudaMemcpy((void*) debugp, (void*) debugp_d, 100*sizeof(float), cudaMemcpyDeviceToHost) );
  for(int i=0; i<30; i++){
    cout << i << " " << debugp[i] << endl;
  }
#endif

  CUDA_SAFE_CALL( cudaMemcpy((void *) vola,(void *) vol_d, nvert*sizeof(float), cudaMemcpyDeviceToHost) );
  //cout << endl;
  //for(int i=0; i<30; i++) cout << i << " " << vola[i] << endl;
  cudaFree( vol_d   );

  cout << " [OK]" << endl;

  // seting epsilon to something meaningful based on the geometry size
  eps = 1e-10f;
  for(unsigned int i=0; i<3; i++)
    eps = max((dmax.a[i]-dmin.a[i])*1e-5f,eps);
  CUDA_SAFE_CALL( cudaMemcpyToSymbol(crixus_d::eps   , &eps   , sizeof(float)) );

  // searching for special boundaries
  int *sbid;
  int *sbid_d;
  bool sbpresent = false;
  bool needsUpdate = false;
  bool *needsUpdate_d;
  string cfname;
  int flen = strlen(argv[1]);
  int sbi = 0;
  while(true){
    sbi++;
    cfname = configfname.substr(0,configfname.length()-4);
    cfname += "_sbgrid_";
    stringstream ss;
    ss << sbi;
    cfname += ss.str();
    cfname += ".stl";
    string option = "mesh" + ss.str();
    cfname = config.Get("special_boundary_grids", option, cfname);

    cout << "\nChecking whether special boundary grid #" << sbi << " (" << cfname << ") is available ...";
    stl_file.open(cfname.c_str(), ios::in);
    if(!stl_file.is_open()){
      cout << " [NO]" << endl;
      break;
    }
    else{
      cout << " [YES]" << endl;
      cout << "Checking whether special boundary stl file #" << sbi << " is binary ...";
      bool issolid = true;
      char header[6] = "solid";
      for (int i=0; i<5; i++){
        char dum;
        stl_file.read((char *)&dum, sizeof(char));
        if(dum!=header[i]){
          issolid = false;
          break;
        }
      }
      stl_file.close();
      if(issolid){
        cout << " [NO]" << endl;
        break;
      }
      else{
        cout << " [YES]" << endl;
        // reopen file in binary mode
        stl_file.open(cfname.c_str(), ios::in | ios::binary);
      }
    }
    int sbnvert, sbnbe;
    uf4 *sbposa;
    ui4 *sbep;
    // read header
    for (int i=0; i<20; i++){
      float dum;
      stl_file.read((char *)&dum, sizeof(float));
    }
    // get number of facets
    stl_file.read((char *)&num_of_facets, sizeof(int));
    cout << "Reading " << num_of_facets << " facets of special boundary geometry #" << sbi << " ...";
    fflush(stdout);

    // define variables
    pos.clear();
    epv.clear();
    for(int i=0;i<3;i++){
      ddum[i] = 0.;
      idum[i] = 0;
    }

    // read data
    through = 0;
    while ((through < num_of_facets) & (!stl_file.eof()))
    {
      for (int i=0; i<12; i++)
      {
        stl_file.read((char *)&m_v_floats[i], sizeof(float));
      }
      for(int i=0;i<3;i++) ddum[i] = (float)m_v_floats[i];
      // save the three vertices in an array
      for(int j=0;j<3;j++){
        for(int i=0;i<3;i++){
          ddum[i] = (float)m_v_floats[i+3*(j+1)];
        }
        all_vert_pos.push_back(ddum);
        idum[j]=through*3 + j;
      }
      init_epv.push_back(idum);
      stl_file.read((char *)&attribute, sizeof(short));
      through++;
    }
    remove_duplicate_vertices(all_vert_pos, init_epv, pos, epv, dr);
    all_vert_pos.clear();
    init_epv.clear();
    stl_file.close();
    if(num_of_facets != epv.size()){
      cout << " [FAILED]" << endl;
      return READ_ERROR;
    }
    sbnvert = pos.size();
    sbnbe   = epv.size();
    //create and copy vectors to arrays
    sbposa  = new uf4   [sbnvert];
    sbep    = new ui4   [sbnbe];
    for(unsigned int i=0; i<max(sbnvert,sbnbe); i++){
      if(i<sbnbe){
        for(int j=0; j<3; j++){
          sbep[i].a[j] = epv[i][j];
        }
      }
      if(i<sbnvert){
        for(unsigned int j=0; j<3; j++)
          sbposa[i].a[j] = pos[i][j];
      }
    }
    pos.clear();
    epv.clear();
    sbpresent = true;
    cout << " [OK]" << endl;

    // after reading in data for special boundaries copy data to gpu and identify interior boundary segments and surrounded vertex particles
    sbid = new int[nbe+nvert];
    for(int i=0; i<nbe+nvert; i++) sbid[i] = 0;
    uf4 *sbpos_d;
    ui4 *sbep_d;
    if(sbi==1){
      CUDA_SAFE_CALL( cudaMalloc((void **) &needsUpdate_d , sizeof(bool)) );
      CUDA_SAFE_CALL( cudaMalloc((void **) &sbid_d , (nvert+nbe)*sizeof(int)) );
      CUDA_SAFE_CALL( cudaMemcpy((void *) needsUpdate_d, (void *) &needsUpdate, sizeof(bool), cudaMemcpyHostToDevice) );
      CUDA_SAFE_CALL( cudaMemcpy((void *) sbid_d, (void *) sbid, (nvert+nbe)*sizeof(int), cudaMemcpyHostToDevice) );
    }
    CUDA_SAFE_CALL( cudaMalloc((void **) &sbpos_d  ,     sbnvert*sizeof(uf4)) );
    CUDA_SAFE_CALL( cudaMalloc((void **) &sbep_d   ,       sbnbe*sizeof(ui4)) );
    CUDA_SAFE_CALL( cudaMemcpy((void *) sbpos_d, (void *) sbposa, sbnvert*sizeof(uf4), cudaMemcpyHostToDevice) );
    CUDA_SAFE_CALL( cudaMemcpy((void *) sbep_d , (void *) sbep  ,   sbnbe*sizeof(ui4), cudaMemcpyHostToDevice) );
    numBlocks = (int) ceil((float)nbe/(float)numThreads);
    numBlocks = min(numBlocks,maxblock);

    crixus_d::identifySpecialBoundarySegments<<<numBlocks, numThreads>>> (pos_d, ep_d, nvert, nbe, sbpos_d, sbep_d, sbnbe, sbid_d, sbi);

    //numBlocks = (int) ceil((float)nvert/(float)numThreads);
    //numBlocks = min(numBlocks,maxblock);

    //crixus_d::identifySpecialBoundaryVertices<<<numBlocks, numThreads>>> (sbid_d, sbi, trisize, nvert);

    //numBlocks = (int) ceil((float)nbe/(float)numThreads);
    //numBlocks = min(numBlocks,maxblock);

    //crixus_d::checkForSingularSegments<<<numBlocks, numThreads>>> (pos_d, ep_d, norm_d, surf_d, nvert, nbe, sbid_d, sbi, needsUpdate_d);

    cudaFree( sbpos_d );
    cudaFree( sbep_d  );
  }

  // Declare and initialize per-kent counters of particles.
  // Here sbi is (number_of_special_bounds + 1), so exactly what we need
  const int num_kents = sbi;

  cudaFree( trisize );
  if(sbpresent){
    CUDA_SAFE_CALL( cudaMemcpy((void *) sbid, (void *) sbid_d, (nbe+nvert)*sizeof(int) , cudaMemcpyDeviceToHost) );
    CUDA_SAFE_CALL( cudaMemcpy((void *) &needsUpdate, (void *) needsUpdate_d, sizeof(bool), cudaMemcpyDeviceToHost) );
    if (needsUpdate) {
      cout << "\nInformation: Special boundaries required repositioning of some segments" << endl;
      // copy ep, surf back to host
      CUDA_SAFE_CALL( cudaMemcpy((void *) ep  ,(void *) ep_d  ,         nbe*sizeof(ui4)  , cudaMemcpyDeviceToHost) );
      CUDA_SAFE_CALL( cudaMemcpy((void *) surf,(void *) surf_d,         nbe*sizeof(float), cudaMemcpyDeviceToHost) );
      CUDA_SAFE_CALL( cudaMemcpy((void *) posa,(void *) pos_d , (nvert+nbe)*sizeof(uf4)  , cudaMemcpyDeviceToHost) );
    }
    cudaFree( sbid_d  );
  }

  cudaFree(surf_d  );

  //setting up fluid particles
  cout << "\nDefining fluid particles ..." << endl;

  cfname = configfname.substr(0,configfname.length()-4);
  cfname += "_fshape.stl";
  cfname = config.Get("mesh", "fshape", cfname);

  cout << "Checking whether fluid geometry (" << cfname << ") is available ...";
  fflush(stdout);

  ifstream fstl_file (cfname.c_str(), ios::in);
  bool requireFluidGeomRead = true;
  if(!fstl_file.is_open()){
    cout << " [NO]" << endl;
    requireFluidGeomRead = false;
  }
  else{
    cout << " [YES]" << endl;
    cout << "Checking whether fluid geometry stl file is binary ...";
    fflush(stdout);
    bool issolid = true;
    char header[6] = "solid";
    for (int i=0; i<5; i++){
      char dum;
      fstl_file.read((char *)&dum, sizeof(char));
      if(dum!=header[i]){
        issolid = false;
        break;
      }
    }
    fstl_file.close();
    if(issolid){
      cout << " [NO]" << endl;
    }
    else{
      cout << " [YES]" << endl;
      // reopen file in binary mode
      fstl_file.open(cfname.c_str(), ios::in | ios::binary);
      if(!fstl_file.is_open()){
        cout << "Error: could not reopen fluid geometry file in binary mode" << endl;
        return -1;
      }
    }
  }

  bool set = true;
  // number of vertices and boundary elements of the fluid shape file
  unsigned int fsnvert, fsnbe = 0;
  unsigned int nfluid = 0;
  unsigned int maxf = 0, maxfn;
  int opt;
  unsigned int *fpos, *fpos_d;
  unsigned int *nfi_d;

  set = config.GetBoolean("fluid_container", "use", false);

  if(set){
    // From here on dmin, dmax represent the fluid container and no longer the domain container.
    dmin.a[0] = config.GetReal("fluid_container", "xmin", 1e9);
    dmin.a[1] = config.GetReal("fluid_container", "ymin", 1e9);
    dmin.a[2] = config.GetReal("fluid_container", "zmin", 1e9);
    dmax.a[0] = config.GetReal("fluid_container", "xmax", -1e9);
    dmax.a[1] = config.GetReal("fluid_container", "ymax", -1e9);
    dmax.a[2] = config.GetReal("fluid_container", "zmax", -1e9);
    cout << "Fluid container specified:" << endl;
    cout << "Min coordinates (" << dmin.a[0] << ", " << dmin.a[1] << ", " << dmin.a[2] << ")" << endl;
    cout << "Max coordinates (" << dmax.a[0] << ", " << dmax.a[1] << ", " << dmax.a[2] << ")" << endl;
    CUDA_SAFE_CALL( cudaMemcpyToSymbol(crixus_d::fcmin  , &dmin  , sizeof(uf4  )) );
    CUDA_SAFE_CALL( cudaMemcpyToSymbol(crixus_d::fcmax  , &dmax  , sizeof(uf4  )) );
  }
  else{
    cout << "Using whole geometry as fluid container." << endl;
    for (unsigned int i=0; i<3; i++) {
      if (per[i])
        dmax.a[i] -= dr;
    }
    CUDA_SAFE_CALL( cudaMemcpyToSymbol(crixus_d::fcmin  , &dmin  , sizeof(uf4  )) );
    CUDA_SAFE_CALL( cudaMemcpyToSymbol(crixus_d::fcmax  , &dmax  , sizeof(uf4  )) );
  }

  maxfn = (int)floor((dmax.a[0]-dmin.a[0]+eps)/dr+1)*floor((dmax.a[1]-dmin.a[1]+eps)/dr+1)*floor((dmax.a[2]-dmin.a[2]+eps)/dr+1);
  maxf = (int)ceil(float(maxfn)/8./((float)sizeof(unsigned int)));
  fpos = new unsigned int [maxf];
  CUDA_SAFE_CALL( cudaMalloc((void **) &fpos_d, maxf*sizeof(unsigned int)) );
  CUDA_SAFE_CALL( cudaMalloc((void **) &nfi_d, sizeof(unsigned int)) );
  for(unsigned int i=0; i<maxf; i++) fpos[i] = 0;
  CUDA_SAFE_CALL( cudaMemcpy((void *) fpos_d, (void *) fpos, maxf*sizeof(unsigned int), cudaMemcpyHostToDevice) );

  bool continueFill = true;
  int nFill = 0;
  while(continueFill){
    stringstream fillSection;
    fillSection << "fill_" << nFill;
    string option=config.Get(fillSection.str(), "option", "box");
    if (option=="geometry")
      opt = 2;
    else
      opt = 1;
    cout << "\nOption for fill #" << nFill << ": " << option << endl;
    xmin = xmax = ymin = ymax = zmin = zmax = 0.;

    // data for geometry bounding grid and fluid bounding grid
    uf4 *fposa=NULL, *fnorma=NULL;
    ui4 *fep=NULL;

    if(opt==1){ // fluid based on rectangular box
      xmin = config.GetReal(fillSection.str(), "xmin", 1e9);
      ymin = config.GetReal(fillSection.str(), "ymin", 1e9);
      zmin = config.GetReal(fillSection.str(), "zmin", 1e9);
      xmax = config.GetReal(fillSection.str(), "xmax", -1e9);
      ymax = config.GetReal(fillSection.str(), "ymax", -1e9);
      zmax = config.GetReal(fillSection.str(), "zmax", -1e9);
      cout << "Fluid box specified:" << endl;
      cout << "Min coordinates (" << xmin << ", " << ymin << ", " << zmin << ")" << endl;
      cout << "Max coordinates (" << xmax << ", " << ymax << ", " << zmax << ")" << endl;
      if(xmax-xmin<1e-5*dr || ymax-ymin<1e-5*dr || zmax-zmin<1e-5*dr){
        cout << "\nMistake in input for fluid box dimensions" << endl;
        cout << "Fluid particle definition ... [FAILED]" << endl;
        return FLUID_NDEF;
      }
      if (xmin+eps < dmin.a[0] || xmax-eps > dmax.a[0] ||
          ymin+eps < dmin.a[1] || ymax-eps > dmax.a[1] ||
          zmin+eps < dmin.a[2] || zmax-eps > dmax.a[2]   ) {
        cout << "\nFluid box does not fit into Fluid container with" << endl;
        cout << "\tmin coordinates (" << dmin.a[0] << ", " << dmin.a[1] << ", " << dmin.a[2] << ")" << endl;
        cout << "\tmax coordinates (" << dmax.a[0] << ", " << dmax.a[1] << ", " << dmax.a[2] << ")" << endl;
        cout << "It is required to set a fluid container explicitly if the fluid is outside the bounding box of the geometry" << endl;
        cout << "Fluid particle definition ... [FAILED]" << endl;
        return FLUID_BBOX_TOO_SMALL;
      }
      numBlocks = (int) ceil((float)maxf/(float)numThreads);
      numBlocks = min(numBlocks,maxblock);

      Lock lock_f;
      unsigned int nfi=0;
      CUDA_SAFE_CALL( cudaMemcpy((void *) nfi_d, (void *) &nfi, sizeof(unsigned int), cudaMemcpyHostToDevice) );

      crixus_d::fill_fluid<<<numBlocks, numThreads>>> (fpos_d, nfi_d, xmin, xmax, ymin, ymax, zmin, zmax, lock_f);

      CUDA_SAFE_CALL( cudaMemcpy((void *) &nfi, (void *) nfi_d, sizeof(unsigned int), cudaMemcpyDeviceToHost) );
      nfluid += nfi;

    }

    else if(opt==2){ // fluid based on geometry
      // get seed point
      float spos[3], dr_wall;
      spos[0] = config.GetReal(fillSection.str(), "xseed", 1e9);
      spos[1] = config.GetReal(fillSection.str(), "yseed", 1e9);
      spos[2] = config.GetReal(fillSection.str(), "zseed", 1e9);
      cout << "Seed point (" << spos[0] << ", " << spos[1] << ", " << spos[2] << ")" << endl;
      dr_wall = config.GetReal(fillSection.str(), "dr_wall", dr);
      cout << "Distance from fluid particles to vertices and segments: " << dr_wall << endl;
      CUDA_SAFE_CALL( cudaMemcpyToSymbol(crixus_d::dr_wall, &dr_wall, sizeof(float)) );
      // initialize placing of seed point
      int ispos = (int)round((spos[0]-dmin.a[0]+eps)/dr);
      int jspos = (int)round((spos[1]-dmin.a[1]+eps)/dr);
      int kspos = (int)round((spos[2]-dmin.a[2]+eps)/dr);
      int idimg = (int)floor((dmax.a[0]-dmin.a[0]+eps)/dr+1);
      int jdimg = (int)floor((dmax.a[1]-dmin.a[1]+eps)/dr+1);
      int sInd = ispos + jspos*idimg + kspos*idimg*jdimg;
      // number of vert & bound elements of both geometry & fshape mesh
      unsigned int fnvert, fnbe = nbe;

      // initialize geometry if first run
      if(requireFluidGeomRead){
        requireFluidGeomRead = false;

        cudaFree(norm_d  );
        cudaFree(pos_d   );
        cudaFree(ep_d    );

        // read fluid geometry
        // read header
        for (int i=0; i<20; i++){
        float dum;
        fstl_file.read((char *)&dum, sizeof(float));
        }
        // get number of facets
        fstl_file.read((char *)&num_of_facets, sizeof(int));
        cout << "Reading " << num_of_facets << " facets of fluid geometry ...";
        fflush(stdout);

        // define variables
        pos.clear();
        norm.clear();
        epv.clear();
        for(int i=0;i<3;i++){
          ddum[i] = 0.;
          idum[i] = 0;
        }

        // read data
        through = 0;
        while ((through < num_of_facets) & (!fstl_file.eof()))
        {
          for (int i=0; i<12; i++)
          {
            fstl_file.read((char *)&m_v_floats[i], sizeof(float));
          }
          // save the three vertices in an array
          for(int j=0;j<3;j++){
            for(int i=0;i<3;i++){
              ddum[i] = (float)m_v_floats[i+3*(j+1)];
            }
            all_vert_pos.push_back(ddum);
            idum[j]=through*3 + j;
          }
          init_epv.push_back(idum);
          // get normal of triangle
          float lenNorm = 0.0;
          for(int i=0;i<3;i++){
            ddum[i] = (float)m_v_floats[i];
            lenNorm += ddum[i]*ddum[i];
          }
          // this is for blender if stl files are saved without normals
          // here we don't care for the orientation so let's just compute it
          if(lenNorm < eps){
            uf4 v10, v20;
            for(int i=0; i<3; i++){
              v10.a[i] = pos[idum[1]-nvert][i] - pos[idum[0]-nvert][i];
              v20.a[i] = pos[idum[2]-nvert][i] - pos[idum[0]-nvert][i];
            }
            uf4 tnorm = cross(v10, v20);
            for(int i=0; i<3; i++)
              ddum[i] = tnorm.a[i];
          }
          norm.push_back(ddum);
          fstl_file.read((char *)&attribute, sizeof(short));
          through++;
        }
        remove_duplicate_vertices(all_vert_pos, init_epv, pos, epv, dr);
        all_vert_pos.clear();
        init_epv.clear();
        fstl_file.close();
        if(num_of_facets != norm.size()){
          cout << " [FAILED]" << endl;
          return READ_ERROR;
        }
        fsnvert = pos.size();
        fsnbe   = norm.size();
        cout << " [OK]" << endl;
        cout << "Merging arrays and preparing device for filling ...";
        fflush(stdout);

        fnorma = new uf4   [nbe+fsnbe];
        fposa  = new uf4   [nvert+fsnvert];
        fep    = new ui4   [nbe+fsnbe];
        // copying vertices and segments of original boundary
        for(unsigned int i=0; i<max(nbe,nvert); i++){
          if(i<nbe){
            fnorma[i] = norma[i];
            fep   [i] = ep   [i];
          }
          if(i<nvert){
            fposa [i] = posa [i];
          }
        }
        // copying vertices and segments of free-surface mesh
        for(unsigned int i=0; i<max(fsnvert,fsnbe); i++){
          if(i<fsnbe){
            for(int j=0; j<3; j++){
              fnorma[i+nbe].a[j] = norm[i][j];
              fep[i+nbe].a[j] = epv[i][j] + nvert;
            }
          }
          if(i<fsnvert){
            for(int j=0; j<3; j++)
              fposa[i+nvert].a[j] = pos[i][j];
          }
        }
        fnvert = nvert + fsnvert;
        fnbe = nbe + fsnbe;
        pos.clear();
        epv.clear();
        norm.clear();
        CUDA_SAFE_CALL( cudaMalloc((void **) &norm_d,   fnbe*sizeof(uf4  )) );
        CUDA_SAFE_CALL( cudaMalloc((void **) &pos_d , fnvert*sizeof(uf4  )) );
        CUDA_SAFE_CALL( cudaMalloc((void **) &ep_d  ,   fnbe*sizeof(ui4  )) );
        CUDA_SAFE_CALL( cudaMemcpy((void *) norm_d, (void *) fnorma,   fnbe*sizeof(uf4), cudaMemcpyHostToDevice) );
        CUDA_SAFE_CALL( cudaMemcpy((void *) pos_d , (void *) fposa , fnvert*sizeof(uf4), cudaMemcpyHostToDevice) );
        CUDA_SAFE_CALL( cudaMemcpy((void *) ep_d  , (void *) fep   ,   fnbe*sizeof(ui4), cudaMemcpyHostToDevice) );

        numBlocks = (int) ceil((float)maxf/(float)numThreads);
        numBlocks = min(numBlocks,maxblock);
        cout << " [OK]" << endl;
      } // end requireFluidGeomRead

      unsigned int nfi;
      unsigned int iteration = 0;
      do{
        Lock lock_f;
        iteration++;
        nfi = 0;
        CUDA_SAFE_CALL( cudaMemcpy((void *) nfi_d, (void *) &nfi, sizeof(unsigned int), cudaMemcpyHostToDevice) );

        crixus_d::fill_fluid_complex<<<numBlocks,numThreads/4>>> (fpos_d, nfi_d, norm_d, ep_d, pos_d, fnbe, sInd, lock_f, fsnbe, iteration, cell_idx_d);
        //crixus_d::fill_fluid_complex<<<numBlocks, numThreads>>> (fpos_d, nfi_d, norm_d, ep_d, pos_d, fnbe, sInd, lock_f, fsnbe, iteration, cell_idx_d);

        CUDA_SAFE_CALL( cudaMemcpy((void *) &nfi, (void *) nfi_d, sizeof(unsigned int), cudaMemcpyDeviceToHost) );
        nfluid += nfi;
      } while(nfi > 0 && iteration < max_iterations);
      if (iteration == max_iterations && nfi > 0)
        cout << "[Information] Complex filling terminated due to reaching max_iterations." << endl;
    }

    stringstream fillSectionTest;
    fillSectionTest << "fill_" << (nFill+1);
    if (config.Get(fillSectionTest.str(), "option", "UNKNOWN") == "UNKNOWN") {
      continueFill = false;
      if (!requireFluidGeomRead) {
        delete [] fposa;
        delete [] fnorma;
        delete [] fep;
      }
    }
    nFill++;
  }
  CUDA_SAFE_CALL( cudaMemcpy((void *) fpos, (void *) fpos_d, maxf*sizeof(unsigned int), cudaMemcpyDeviceToHost) );
  cout << "\nCreation of " << nfluid << " fluid particles completed. [OK]" << endl;
  cudaFree( fpos_d );
  cudaFree( nfi_d  );
  cudaFree( norm_d );
  cudaFree( pos_d  );
  cudaFree( ep_d   );

  //prepare output structure for particles
  cout << "Creating and initializing of output buffer of particles ...";
  fflush(stdout);
  OutBuf *buf, *beBuf;

  int num_fluid_particles = 0;
#ifndef bdebug
  unsigned int nelem = nvert+nbe+nfluid;
#else
  unsigned int nelem = nvert+nbe+nfluid+debugs;
#endif
  buf = new OutBuf[nelem];
  // buffer for boundary elements
  beBuf = new OutBuf[nbe];
  int k=0;
  unsigned int m,n,imin[3];
  float fluid_vol = pow(dr,3);
  imin[0] = int(floor((dmax.a[0]-dmin.a[0]+eps)/dr))+1;
  imin[1] = int(floor((dmax.a[1]-dmin.a[1]+eps)/dr))+1;
  imin[2] = int(floor((dmax.a[2]-dmin.a[2]+eps)/dr))+1;
  //free particles
  for(unsigned int j=0; j<maxfn; j++){
    int i = j/bitPerUint;
    int l = j%bitPerUint;
    m = 1 << l;
    if(fpos[i] & m){
      m = j/(imin[1]*imin[0]);
      buf[k].z = dmin.a[2]+dr*(float)m;
      n = j%(imin[1]*imin[0]);
      m = n/imin[0];
      buf[k].y = dmin.a[1]+dr*(float)m;
      m = n%imin[0];
      buf[k].x = dmin.a[0]+dr*(float)m;
      buf[k].nx = 0.;
      buf[k].ny = 0.;
      buf[k].nz = 0.;
      buf[k].vol = fluid_vol;
      buf[k].surf = 0.;
      buf[k].kpar = 1;
      buf[k].kfluid = 1;
      buf[k].kent = 0;
      buf[k].kparmob = 0;
      buf[k].iref = k;
      buf[k].ep1 = 0;
      buf[k].ep2 = 0;
      buf[k].ep3 = 0;
      k++;
      num_fluid_particles++;
    }
  }
  //vertex particles
  int *nvshift;
  nvshift = new int[nvert];
  for(unsigned int i=0; i<nvert; i++)
    nvshift[i] = 0;
  int ishift = 0;
  for(unsigned int i=0; i<nvert; i++){
    if(posa[i].a[0] < -1e9){
      nelem--;
      ishift++;
      continue;
    }
    nvshift[i] = ishift;
    buf[k].x = posa[i].a[0];
    buf[k].y = posa[i].a[1];
    buf[k].z = posa[i].a[2];
    buf[k].nx = 0.;
    buf[k].ny = 0.;
    buf[k].nz = 0.;
    buf[k].vol = vola[i];
    buf[k].surf = 0.;
    buf[k].kpar = 2;
    buf[k].kfluid = 1;
    if(sbpresent)
      buf[k].kent = sbid[i];
    else
      buf[k].kent = 0;
    buf[k].kparmob = 0;
    buf[k].iref = k;
    buf[k].ep1 = 0;
    buf[k].ep2 = 0;
    buf[k].ep3 = 0;
    k++;
  }
  const unsigned int nCur = k;
  //boundary segments
  //these are preliminarily written into beBuf because we might need to rearrange them
  //count the numbers of special boundary elements
  unsigned int *nsbe, *isbe;
  nsbe = new unsigned int[sbi];
  isbe = new unsigned int[sbi];
  for(unsigned int i=0; i<sbi; i++)
    nsbe[i] = 0;
  for(unsigned int i=nvert; i<nvert+nbe; i++){
    beBuf[k-nCur].x = posa[i].a[0];
    beBuf[k-nCur].y = posa[i].a[1];
    beBuf[k-nCur].z = posa[i].a[2];
    beBuf[k-nCur].nx = norma[i-nvert].a[0];
    beBuf[k-nCur].ny = norma[i-nvert].a[1];
    beBuf[k-nCur].nz = norma[i-nvert].a[2];
    beBuf[k-nCur].vol = 0.;
    beBuf[k-nCur].surf = surf[i-nvert];
    beBuf[k-nCur].kpar = 3;
    beBuf[k-nCur].kfluid = 1;
    if(sbpresent){
      beBuf[k-nCur].kent = sbid[i];
      nsbe[sbid[i]]++;
    }
    else
      beBuf[k-nCur].kent = 0;
    beBuf[k-nCur].kparmob = 0;
    beBuf[k-nCur].iref = k;
    beBuf[k-nCur].ep1 = nfluid+ep[i-nvert].a[0] - nvshift[ep[i-nvert].a[0]];
    beBuf[k-nCur].ep2 = nfluid+ep[i-nvert].a[1] - nvshift[ep[i-nvert].a[1]];
    beBuf[k-nCur].ep3 = nfluid+ep[i-nvert].a[2] - nvshift[ep[i-nvert].a[2]];
    k++;
  }
  // isbe contains the current index of each sbi
  isbe[0] = 0;
  for(unsigned int i=1; i<sbi; i++)
    isbe[i] = nsbe[i-1] + isbe[i-1];
  // copy beBuf into buf while reordering if required
  for(unsigned int i=0; i<nbe; i++){
    unsigned int l = nCur + isbe[beBuf[i].kent];
    buf[l] = beBuf[i];
    buf[l].iref = l;
    isbe[beBuf[i].kent]++;
  }
  delete [] nvshift;
#ifdef bdebug
  //debug
  for(unsigned int i=0; i<debugs; i++){
    buf[k].x = debug[i].a[0];
    buf[k].y = debug[i].a[1];
    buf[k].z = debug[i].a[2];
    buf[k].nx = 0;
    buf[k].ny = 0;
    buf[k].nz = 0;
    buf[k].vol = debug[i].a[3];
    buf[k].surf = 0.;
    buf[k].kpar = 4;
    buf[k].kfluid = 1;
    buf[k].kent = 1;
    buf[k].kparmob = 0;
    buf[k].iref = k;
    buf[k].ep1 = 0;
    buf[k].ep2 = 0;
    buf[k].ep3 = 0;
    k++;
  }
#endif
  cout << " [OK]" << endl;

  //Output of particles
  int err = 0;
  string outfformat = config.Get("output", "format", "vtu");
  if (outfformat == "h5sph")
    opt = 2;
  else
    opt = 1;
  cout << "Output format: " << outfformat << endl;
  string outname = configfname.substr(0,configfname.length()-4);
  outname = config.Get("output", "name", outname);

  // if split_output is active, we save fluid parts separately plus we split bounds by kent
  const bool split_output = config.GetBoolean("output", "split", false);

  if (split_output) {
    cout << "Sorting particles according to special boundary id...";
    fflush(stdout);

    // allocate per-Kent arrays
    int num_parts_per_kent[num_kents]; // equivalent to nsbe?
    OutBuf **perKentBufs = new OutBuf*[num_kents]; // particle[kent][part_idx]
    int *perKentCopiedParts = new int[num_kents]; // #copied_particles[kent]

    // Count number of particles for each kent. It would be more efficient to count them
    // while creating the particles, but that approach led to discrepancies still to be
    // investigated
    for (int k = 0; k < num_kents; k++)
      num_parts_per_kent[k] = 0;
    for (int i = 0; i < nelem; i++)
      num_parts_per_kent[buf[i].kent]++;

    // allocate an array for each kent
    for (int k = 0; k < num_kents; k++) {
      int allocate_for_curr_kent = num_parts_per_kent[k];
      // kent 0 includes fluid particles; no need to copy them
      if (k == 0)
        allocate_for_curr_kent -= num_fluid_particles;
      // do not allocate if there are 0 parts with current kent (unlikely)
      if (allocate_for_curr_kent > 0)
        perKentBufs[k] = new OutBuf[ allocate_for_curr_kent ];
      else
        perKentBufs[k] = NULL;
      // initialize progressive index
      perKentCopiedParts[k] = 0;
    }

    // copy particles, excluding fluid ones
    for (int i = num_fluid_particles; i < nelem; i++) {
      const int curr_particle_kent = buf[i].kent;
      // ensure there is at least one particle with given kent
      if (num_parts_per_kent[curr_particle_kent] > 0) {
          if (perKentCopiedParts[curr_particle_kent] >= num_parts_per_kent[curr_particle_kent]) {
            cout << "Internal error: counted " << num_parts_per_kent[curr_particle_kent] << " particles with kent " <<
              curr_particle_kent << ", found more. Aborting..." << endl;
            return INTERNAL_ERROR;
          }
          perKentBufs[ curr_particle_kent ][ perKentCopiedParts[curr_particle_kent] ] = buf[i];
          perKentCopiedParts[ curr_particle_kent ] ++;
      }
     }
    cout << " [OK]" << endl;
    cout << "Counted:" << endl;
    cout << " - Fluid particles: " << num_fluid_particles << endl;
    for (int k = 0; k < num_kents; k++)
      cout << " - Boundary particles, kent " << k << ": " << num_parts_per_kent[k] << endl;

    // save fluid particles...
    string curr_outname = outname + ".fluid";
    err = generic_output(buf, 0, num_fluid_particles, curr_outname.c_str(), opt);
    if (err != 0) return err;

    // ...then save a different file for each kent
    for (int k = 0; k < num_kents; k++) {
      // yes, int to string in 2014...
      std::stringstream sstm;
      sstm << outname << ".boundary.kent" << k;
      string curr_outname = sstm.str();

      // initialize range of particles to be save
      int num_parts_with_this_kent = perKentCopiedParts[k];

      // there might be no boundary particles with kent 0, thus the check
      if (num_parts_with_this_kent > 0) {
          err = generic_output(perKentBufs[k], 0, num_parts_with_this_kent, curr_outname.c_str(), opt);
          if (err != 0) return err;
      }
    }

    // free temporary arrays
    for (int k = 0; k < num_kents; k++)
      delete [] perKentBufs[k];
    delete [] perKentBufs;
    delete [] perKentCopiedParts;

  } else { // !split_output

    // save all particles into a single file
    err = generic_output(buf, 0, nelem, outname.c_str(), opt);
    if (err != 0) return err;

  }

  //Free memory
  //Arrays
  delete [] norma;
  delete [] posa;
  delete [] vola;
  delete [] surf;
  delete [] ep;
  delete [] buf;
  delete [] fpos;

  //End
  return 0;
}
#endif
